import 'dart:typed_data';
import '../core/filesystem/filesystem.dart';

Future<String> readLocal(Uri uri) =>
    throw UnsupportedError('Local paths unavailable');
Future<Uint8List> readLocalBytes(Uri uri) =>
    throw UnsupportedError('Local paths unavailable');
Future<void> writeLocal(Uri uri, String text) =>
    throw UnsupportedError('Local paths unavailable');
Future<List<FileEntry>> listLocal(Uri uri) =>
    throw UnsupportedError('Directory access unavailable');
