/// A minimal mirror of the drive file reference used by the OAuth client
/// metadata (`picture`/`background`); only the fields the authorize sheet
/// reads are kept.
class CloudFileReference {
  final String id;
  const CloudFileReference({required this.id});

  factory CloudFileReference.fromJson(Map<String, dynamic> json) =>
      CloudFileReference(id: json['id']?.toString() ?? '');
}

class AuthorizeClientInfo {
  final String clientName;
  final String? homeUri;
  final CloudFileReference? picture;
  final CloudFileReference? background;
  final List<String> scopes;
  final String? description;

  const AuthorizeClientInfo({
    required this.clientName,
    this.homeUri,
    this.picture,
    this.background,
    this.scopes = const [],
    this.description,
  });

  factory AuthorizeClientInfo.fromJson(Map<String, dynamic> json) {
    return AuthorizeClientInfo(
      clientName: (json['client_name'] as String?)?.trim().isNotEmpty == true
          ? (json['client_name'] as String).trim()
          : (json['name'] as String?)?.trim() ?? 'Unknown App',
      homeUri: (json['home_uri'] as String?)?.trim(),
      picture: json['picture'] is Map<String, dynamic>
          ? CloudFileReference.fromJson(
              json['picture'] as Map<String, dynamic>,
            )
          : null,
      background: json['background'] is Map<String, dynamic>
          ? CloudFileReference.fromJson(
              json['background'] as Map<String, dynamic>,
            )
          : null,
      scopes:
          (json['scopes'] as List?)?.map((item) => item.toString()).toList() ??
          _readScopeString(json['scope']),
      description: (json['description'] as String?)?.trim(),
    );
  }

  static List<String> _readScopeString(dynamic raw) {
    if (raw is! String || raw.trim().isEmpty) return const [];
    return raw.split(RegExp(r'\s+')).where((item) => item.isNotEmpty).toList();
  }
}
