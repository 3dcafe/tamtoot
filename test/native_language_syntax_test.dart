import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tamtoot/core/persistence/schema.dart';
import 'package:tamtoot/languages/language_registry.dart';
import 'language_syntax_test.dart' show loadLanguage, scopeAt;

void main() {
  test(
    'custom raw-string terminators validate their capture configuration',
    () {
      final manifest = jsonEncode({
        'schemaVersion': 1,
        'packageVersion': '0.1.0',
        'id': 'test',
        'name': 'Test',
        'extensions': ['.test'],
      });
      for (final invalid in [
        {'begin': 'x', 'end': 'y', 'scope': 'string', 'endPrefix': ')'},
        {'begin': '(x)', 'endCapture': 1, 'scope': 'string', 'endSuffix': 42},
        {'begin': 'x', 'endCapture': 2, 'scope': 'string', 'endPrefix': ')'},
      ]) {
        expect(
          () => LanguagePackageLoader().load(
            manifest,
            jsonEncode({
              'schemaVersion': 1,
              'packageVersion': '0.1.0',
              'rules': [invalid],
            }),
          ),
          throwsA(isA<SchemaException>()),
        );
      }
    },
  );
  test(
    'C, C++ and assembly dialects resolve without interfering with existing languages',
    () {
      final registry = LanguageRegistry();
      for (final id in bundledLanguageIds) {
        registry.register(loadLanguage(id));
      }
      for (final entry in {
        'main.c': 'c',
        'main.C': 'cpp',
        'generated.i': 'c',
        'generated.I': 'cpp',
        'generated.ii': 'cpp',
        'main.cpp': 'cpp',
        'main.cc': 'cpp',
        'lib.h': 'cpp',
        'lib.hpp': 'cpp',
        'code.asm': 'asm',
        'code.inc': 'asm',
        'code.s': 'gas',
        'code.S': 'gas',
        'code.arm.s': 'arm',
        'code.aarch64.s': 'aarch64',
        'code.arm64.s': 'aarch64',
        r'C:\project\code.cpp': 'cpp',
        'config.json': 'json',
      }.entries) {
        expect(registry.forPath(entry.key)?.id, entry.value, reason: entry.key);
      }
    },
  );
  test(
    'C highlights preprocessing, types, function calls, strings and numbers',
    () {
      final c = loadLanguage('c');
      expect(scopeAt(c, '#include <stdio.h>', '#include'), 'directive');
      expect(scopeAt(c, '#include <stdio.h>', '<stdio.h>'), 'string');
      expect(scopeAt(c, 'int main(void) {', 'int'), 'type');
      expect(scopeAt(c, 'int main(void) {', 'main'), 'function');
      expect(scopeAt(c, 'return 0x1.fp+2;', 'return'), 'keyword');
      expect(scopeAt(c, 'return 0x1.fp+2;', '0x1.fp+2'), 'number');
      expect(scopeAt(c, 'printf("// text"); // comment', '// text'), 'string');
      final comment = c.tokenizeLine('/* start');
      expect(
        c.tokenizeLine('still comment', comment.state).tokens.single.scope,
        'comment',
      );
      expect(
        c
            .tokenizeLine('*/ int x;', comment.state)
            .tokens
            .any((t) => t.scope == 'type'),
        true,
      );
    },
  );
  test(
    'C++ supports templates, modern keywords and matching raw-string delimiters',
    () {
      final cpp = loadLanguage('cpp');
      expect(
        scopeAt(cpp, 'template <typename T> class Box {};', 'template'),
        'keyword',
      );
      expect(scopeAt(cpp, 'co_await work();', 'co_await'), 'keyword');
      expect(scopeAt(cpp, 'std::vector<int> values;', 'vector'), 'type');
      final raw = cpp.tokenizeLine('auto s = R"tag(first');
      expect(raw.state, isNotNull);
      final middle = cpp.tokenizeLine(')" // not the end', raw.state);
      expect(middle.tokens.single.scope, 'string');
      expect(middle.state, isNotNull);
      final end = cpp.tokenizeLine(')tag"; return 0;', middle.state);
      expect(end.state, isNull);
      expect(end.tokens.any((t) => t.scope == 'keyword'), true);
      expect(cpp.tokenizeLine('R"(plain)"').state, isNull);
    },
  );
  test(
    'Intel NASM/MASM highlights labels, prefixes, all instruction positions and SIMD registers',
    () {
      final asm = loadLanguage('asm');
      expect(scopeAt(asm, 'start: mov rax, 60 ; exit', 'start:'), 'function');
      expect(scopeAt(asm, 'start: mov rax, 60 ; exit', 'mov'), 'keyword');
      expect(scopeAt(asm, 'MOV RAX, 60', 'RAX'), 'type');
      expect(scopeAt(asm, 'lock add [rax], ebx', 'add'), 'keyword');
      expect(scopeAt(asm, 'vaddps zmm31, zmm1, zmm2', 'vaddps'), 'keyword');
      expect(scopeAt(asm, 'vaddps zmm31, zmm1, zmm2', 'zmm31'), 'type');
      expect(scopeAt(asm, '%define COUNT 4', '%define'), 'directive');
      expect(scopeAt(asm, 'section .text', 'section'), 'directive');
      expect(scopeAt(asm, 'mov eax, 0FFh', '0FFh'), 'number');
      expect(
        scopeAt(asm, 'db "text; literal" ; comment', 'text; literal'),
        'string',
      );
      expect(
        scopeAt(asm, 'db "text; literal" ; comment', '; comment'),
        'comment',
      );
    },
  );
  test(
    'GNU AT&T distinguishes register prefixes and immediates from directives',
    () {
      final gas = loadLanguage('gas');
      expect(scopeAt(gas, r'movq $60, %rax # exit', 'movq'), 'keyword');
      expect(scopeAt(gas, r'movq $60, %rax # exit', '%rax'), 'type');
      expect(scopeAt(gas, r'movq $60, %rax # exit', r'$60'), 'number');
      expect(scopeAt(gas, r'movq $60, %rax # exit', '# exit'), 'comment');
      expect(scopeAt(gas, '.globl _start', '.globl'), 'directive');
      expect(scopeAt(gas, 'fstp %st(0)', '%st(0)'), 'type');
    },
  );
  test(
    'ARM and AArch64 keep immediate operands and instruction separators distinct from comments',
    () {
      final arm = loadLanguage('arm'), a64 = loadLanguage('aarch64');
      expect(scopeAt(arm, 'mov r0, #42 @ value', '#42'), 'number');
      expect(scopeAt(arm, 'mov r0, #42 @ value', '@ value'), 'comment');
      expect(scopeAt(arm, 'mov r0, #42 @ value', 'r0'), 'type');
      expect(scopeAt(a64, 'add x0, x1, #16 // value', '#16'), 'number');
      expect(scopeAt(a64, 'add x0, x1, #16 // value', '// value'), 'comment');
      expect(scopeAt(a64, 'fadd v0.4s, v1.4s, v2.4s', 'v0.4s'), 'type');
      expect(scopeAt(a64, 'mov x0, #1; ret', 'ret'), 'keyword');
    },
  );
}
