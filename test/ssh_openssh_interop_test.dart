import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/ssh/host_keys/ssh_host_keys.dart';
import 'package:tamtoot/core/ssh/ssh_error.dart';
import 'package:tamtoot/core/ssh/transport/ssh_codec.dart';
import 'package:tamtoot/core/ssh/transport/ssh_transport.dart';
import 'package:tamtoot/platform/ssh_crypto/ssh_crypto_io.dart';
import 'package:tamtoot/platform/ssh_wire_io.dart';
import 'ssh_native_support.dart';
import 'support.dart';

// OpenSSH binaries are independent *test servers*, never a client dependency.
class LocalSshServer {
  LocalSshServer(this.directory, this.port, this.keyPath);
  final Directory directory;
  final int port;
  final String keyPath;
  Process? process;
  final log = StringBuffer();
  Future<void> start() async {
    final config = File('${directory.path}/sshd.conf');
    await config.writeAsString('''Port $port
ListenAddress 127.0.0.1
HostKey $keyPath
PidFile ${directory.path}/sshd.pid
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication no
PermitRootLogin no
StrictModes no
LogLevel ERROR
KexAlgorithms curve25519-sha256
HostKeyAlgorithms ssh-ed25519
Ciphers aes256-ctr
MACs hmac-sha2-256-etm@openssh.com
''');
    process = await Process.start('/usr/sbin/sshd', ['-D', '-e', '-f', config.path]);
    process!.stderr.transform(utf8.decoder).listen((chunk) { if (log.length < 8192) log.write(chunk); });
    process!.stdout.drain<void>();
    for (var i=0;i<50;i++) {
      try { final probe = await Socket.connect('127.0.0.1',port,timeout:const Duration(milliseconds:100));probe.destroy();return; }
      on SocketException { await Future<void>.delayed(const Duration(milliseconds:100)); }
    }
    throw StateError('Local test sshd did not start: $log');
  }
  Future<void> stop() async {
    final p=process; process=null;
    if(p==null) return;
    p.kill();
    try { await p.exitCode.timeout(const Duration(seconds:3)); }
    on TimeoutException {p.kill(ProcessSignal.sigkill);await p.exitCode;}
  }
}
Future<void> makeHostKey(String path) async {
  final result=await Process.run('/usr/bin/ssh-keygen',['-q','-t','ed25519','-N','','-f',path]);
  if(result.exitCode!=0) throw StateError('Unable to generate isolated SSH test host key.');
}
class SignatureProxy {
  SignatureProxy(this.server, this.targetPort);
  final ServerSocket server;
  final int targetPort;
  final sockets=<Socket>[];
  bool tampered=false;
  Future<void> start() async {
    server.listen((client) async {
      final upstream=await Socket.connect('127.0.0.1',targetPort);
      sockets.addAll([client,upstream]);
      client.listen(upstream.add,onDone:upstream.destroy,onError:(Object _)=>upstream.destroy());
      var pending=<int>[], version=false;
      upstream.listen((chunk) {
        if(tampered){client.add(chunk);return;}
        pending.addAll(chunk);
        if(!version) {
          final end=pending.indexOf(10);if(end<0)return;
          client.add(pending.sublist(0,end+1));pending=pending.sublist(end+1);version=true;
        }
        while(pending.length>=4) {
          final length=ByteData.sublistView(Uint8List.fromList(pending.sublist(0,4))).getUint32(0);
          if(pending.length<length+4)return;
          final packet=Uint8List.fromList(pending.sublist(0,length+4));pending=pending.sublist(length+4);
          if(packet[5]==31) {
            final reader=SshReader(Uint8List.sublistView(packet,5,packet.length-packet[4]));reader.byte();reader.string();reader.string();
            final signature=SshReader(reader.string());signature.asciiText();signature.string()[0]^=1;tampered=true;
          }
          client.add(packet);
          if(tampered){if(pending.isNotEmpty)client.add(pending);pending=[];return;}
        }
      },onDone:client.destroy,onError:(Object _)=>client.destroy());
    });
  }
  Future<void> close() async { for(final socket in sockets){socket.destroy();}await server.close(); }
}
void main() {
  final available=File('/usr/sbin/sshd').existsSync()&&File('/usr/bin/ssh-keygen').existsSync();
  if(!available){test('OpenSSH test server is available',(){},skip:'OpenSSH test server binaries unavailable');return;}
  late NativeSshCrypto crypto;
  Directory? nativeDirectory;
  late Directory directory;
  late LocalSshServer server;
  setUpAll(() async {
    final native=await buildSshTestCrypto();crypto=native.crypto;nativeDirectory=native.directory;
    directory=await Directory.systemTemp.createTemp('tamtoot-ssh-server-');
    final reservation=await ServerSocket.bind(InternetAddress.loopbackIPv4,0);final port=reservation.port;await reservation.close();
    final key='${directory.path}/hostkey';await makeHostKey(key);
    server=LocalSshServer(directory,port,key);await server.start();
  });
  tearDownAll(() async {await server.stop();await directory.delete(recursive:true);await nativeDirectory?.delete(recursive:true);});
  test('real OpenSSH: encrypted service exchange, strict sequence reset and repeated rekey',() async {
    final hostKeys=SshHostKeys(MemoryStore());
    final transport=SshTransport(crypto:crypto,hostKeys:hostKeys,openWire:openSshWire);
    try {
      var prompts=0;
      await transport.connect('127.0.0.1',server.port,confirm:(challenge) async {prompts++;expect(challenge.key.algorithm,'ssh-ed25519');return SshHostKeyDecision.save;});
      expect(transport.state,SshTransportState.ready);expect(prompts,1);
      expect(transport.incoming.encrypted,isTrue);expect(transport.outgoing.encrypted,isTrue);
      expect(transport.incoming.sequence,0);expect(transport.outgoing.sequence,0);
      final iterator=StreamIterator(transport.messages);
      try {
        final request=(SshWriter()..byte(5)..text('ssh-userauth')).take();
        await transport.send(request);expect(await iterator.moveNext().timeout(const Duration(seconds:5)),isTrue);
        final response=SshReader(iterator.current);expect(response.byte(),6);expect(response.asciiText(),'ssh-userauth');response.end();
        for(var i=0;i<3;i++){await transport.rekey();expect(transport.state,SshTransportState.ready);expect(transport.outgoing.sequence,0);expect(transport.incoming.sequence,0);}
        await Future.wait([transport.rekey(),transport.send(request)]);
        expect(await iterator.moveNext().timeout(const Duration(seconds:5)),isTrue);
        expect(iterator.current[0],6);expect(prompts,1);
      } finally {await iterator.cancel();}
    } finally {await transport.close();}
  },timeout:const Timeout(Duration(seconds:45)));
  test('tampered OpenSSH server signature fails before any trust prompt',() async {
    final listener=await ServerSocket.bind(InternetAddress.loopbackIPv4,0);
    final proxy=SignatureProxy(listener,server.port);await proxy.start();
    final trust=SshHostKeys(MemoryStore());
    final transport=SshTransport(crypto:crypto,hostKeys:trust,openWire:openSshWire);
    var prompts=0;
    try {
      await expectLater(transport.connect('127.0.0.1',listener.port,confirm:(_)async{prompts++;return SshHostKeyDecision.save;}),
        throwsA(isA<SshException>().having((e)=>e.message,'message',contains('signature verification'))));
      expect(proxy.tampered,isTrue);expect(prompts,0);expect(trust.hosts,isEmpty);expect(transport.state,SshTransportState.closed);
    } finally {await transport.close();await proxy.close();}
  },timeout:const Timeout(Duration(seconds:20)));
  test('OpenSSH key replacement stops automatic trust; once does not overwrite saved key',() async {
    final store=MemoryStore(),trust=SshHostKeys(MemoryStore());
    final registry=SshHostKeys(store);
    Future<SshTransport> connect(SshTrustConfirmation confirm) async {
      final t=SshTransport(crypto:crypto,hostKeys:registry,openWire:openSshWire);
      try{await t.connect('127.0.0.1',server.port,confirm:confirm);return t;}catch(_){await t.close();rethrow;}
    }
    final first=await connect((_)async=>SshHostKeyDecision.save);final oldFingerprint=first.serverKey!.fingerprint;await first.close();
    await server.stop();final key='${directory.path}/new-hostkey';await makeHostKey(key);
    server=LocalSshServer(directory,server.port,key);await server.start();
    var prompts=0;
    await expectLater(connect((challenge)async{prompts++;expect(challenge.changed,isTrue);expect(challenge.previousFingerprints,[oldFingerprint]);return SshHostKeyDecision.reject;}),throwsA(isA<SshException>()));
    final once=await connect((challenge)async{prompts++;expect(challenge.key.fingerprint,isNot(oldFingerprint));return SshHostKeyDecision.once;});await once.close();
    expect(SshHostKey(registry.hosts.single.keys.single,crypto).fingerprint,oldFingerprint);
    final add=await connect((_)async=>SshHostKeyDecision.save);await add.close();expect(registry.hosts.single.keys.length,2);
    final known=await connect((_)async{fail('new key should be saved');});await known.close();
    expect(prompts,2);expect(trust.hosts,isEmpty);
  },timeout:const Timeout(Duration(seconds:45)));
}
