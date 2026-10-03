import 'dart:convert';

import 'git_http.dart';
import 'git_service.dart';

/// Result of creating a GitHub repository through the REST API.
class GithubRepository {
  const GithubRepository({
    required this.name,
    required this.fullName,
    required this.cloneUrl,
    required this.htmlUrl,
    required this.private,
  });

  final String name;
  final String fullName;
  final Uri cloneUrl;
  final Uri htmlUrl;
  final bool private;
}

/// Creates an empty repository under the authenticated GitHub user.
///
/// [name] may be `repo` or `owner/repo`. Owner-qualified names use the org
/// endpoint when the owner differs from the authenticated login.
Future<GithubRepository> createGithubRepository(
  GitHttpTransport transport, {
  required String name,
  required GitCredentials credentials,
  bool private = true,
  String description = '',
}) async {
  if (credentials.token == null || credentials.token!.trim().isEmpty) {
    throw GitException(
      'A GitHub access token with repository create permission is required',
    );
  }
  final trimmed = name.trim();
  if (trimmed.isEmpty) {
    throw GitException('Enter a repository name');
  }
  final parts = trimmed
      .split('/')
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
  if (parts.isEmpty || parts.length > 2) {
    throw GitException('Use a repository name like my-app or org/my-app');
  }
  for (final part in parts) {
    if (!RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(part) ||
        part == '.' ||
        part == '..') {
      throw GitException('Invalid repository name: $part');
    }
  }

  final login = await _githubLogin(transport, credentials);
  final owner = parts.length == 2 ? parts.first : login;
  final repoName = parts.last;
  final url = owner.toLowerCase() == login.toLowerCase()
      ? Uri.parse('https://api.github.com/user/repos')
      : Uri.parse('https://api.github.com/orgs/$owner/repos');
  final body = jsonEncode({
    'name': repoName,
    'private': private,
    'auto_init': false,
    if (description.trim().isNotEmpty) 'description': description.trim(),
  });
  final response = await transport.send(
    method: 'POST',
    url: url,
    headers: {
      'Accept': 'application/vnd.github+json',
      'Content-Type': 'application/json',
      'X-GitHub-Api-Version': '2022-11-28',
      ...gitAuthHeaders(credentials),
    },
    body: utf8.encode(body),
  );
  if (response.statusCode == 401 || response.statusCode == 403) {
    throw GitException(
      'GitHub rejected the token (HTTP ${response.statusCode}). '
      'Use a token that can create repositories.',
    );
  }
  if (response.statusCode == 422) {
    throw GitException(
      'GitHub could not create “$owner/$repoName”. '
      'The name may already exist or be invalid.',
    );
  }
  if (response.statusCode < 200 || response.statusCode >= 300) {
    throw GitException(
      'GitHub create repository failed (HTTP ${response.statusCode}): '
      '${_shortBody(response.body)}',
    );
  }
  final data = jsonDecode(utf8.decode(response.body)) as Map<String, dynamic>;
  final clone = data['clone_url'] as String?;
  final html = data['html_url'] as String?;
  final fullName = data['full_name'] as String?;
  if (clone == null || html == null || fullName == null) {
    throw GitException('GitHub response did not include repository URLs');
  }
  return GithubRepository(
    name: (data['name'] as String?) ?? repoName,
    fullName: fullName,
    cloneUrl: Uri.parse(clone),
    htmlUrl: Uri.parse(html),
    private: data['private'] == true,
  );
}

Future<String> _githubLogin(
  GitHttpTransport transport,
  GitCredentials credentials,
) async {
  final response = await transport.send(
    method: 'GET',
    url: Uri.parse('https://api.github.com/user'),
    headers: {
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      ...gitAuthHeaders(credentials),
    },
  );
  if (response.statusCode != 200) {
    throw GitException(
      'Could not read GitHub account (HTTP ${response.statusCode}). '
      'Check the access token.',
    );
  }
  final data = jsonDecode(utf8.decode(response.body)) as Map<String, dynamic>;
  final login = data['login'] as String?;
  if (login == null || login.isEmpty) {
    throw GitException('GitHub account login is missing from the API response');
  }
  return login;
}

String _shortBody(List<int> body) {
  final text = utf8.decode(body, allowMalformed: true).trim();
  if (text.length <= 240) return text;
  return '${text.substring(0, 240)}…';
}
