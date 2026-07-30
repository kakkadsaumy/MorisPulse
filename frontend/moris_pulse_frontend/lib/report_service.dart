import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

class DistrictReportHistory {
  final String note;
  final int severity;
  final bool imageValid;

  DistrictReportHistory({
    required this.note,
    required this.severity,
    required this.imageValid,
  });

  static DistrictReportHistory fromMap(Map<String, dynamic> map) {
    return DistrictReportHistory(
      note: map['note'] as String? ?? '',
      severity: (map['severity'] as num?)?.toInt() ?? 0,
      imageValid: map['image_valid'] as bool? ?? true,
    );
  }
}

class DistrictReport {
  final String id;
  final String category;
  final int severity;
  final String summary;
  final String status;
  final double lat;
  final double lng;
  final DateTime createdAt;
  String? district;

  final String? imageUrl;
  final int confirmations;
  final List<DistrictReportHistory> history;

  DistrictReport({
    required this.id,
    required this.category,
    required this.severity,
    required this.summary,
    required this.status,
    required this.lat,
    required this.lng,
    required this.createdAt,
    this.district,
    this.imageUrl,
    this.confirmations = 0,
    this.history = const [],
  });

  static DistrictReport? fromMap(Map<String, dynamic> map) {
    try {
      // NOTE: the API returns {"location": {"lat": ..., "lng": ...}}
      final loc = map['location'] as Map<String, dynamic>;
      final historyRaw = (map['history'] as List<dynamic>?) ?? [];

      return DistrictReport(
        id: map['id'].toString(),
        category: map['category'] as String? ?? 'unknown',
        severity: (map['severity'] as num?)?.toInt() ?? 0,
        summary: map['summary'] as String? ?? '',
        status: map['status'] as String? ?? 'open',
        lat: (loc['lat'] as num).toDouble(),
        lng: (loc['lng'] as num).toDouble(),
        createdAt:
            DateTime.tryParse(map['created_at'] as String? ?? '') ??
            DateTime.now(),
        district: map['district'] as String?,
        imageUrl: map['image_url'] as String?,
        confirmations: (map['confirmations'] as num?)?.toInt() ?? 0,
        history: historyRaw
            .map(
              (h) => DistrictReportHistory.fromMap(h as Map<String, dynamic>),
            )
            .toList(),
      );
    } catch (_) {
      // Skip malformed rows instead of crashing the whole fetch
      return null;
    }
  }
}

/// Result of a POST to /report/{id}/message — mirrors the backend's
/// {type: "question"|"duplicate"|"submitted"|"error", ...} shape.
class ReportSubmitResult {
  final String type;
  final String? question;
  final String? message;
  final Map<String, dynamic>? report;

  ReportSubmitResult({
    required this.type,
    this.question,
    this.message,
    this.report,
  });

  factory ReportSubmitResult.fromMap(Map<String, dynamic> map) {
    return ReportSubmitResult(
      type: map['type'] as String? ?? 'error',
      question: map['question'] as String?,
      message: map['message'] as String?,
      report: map['report'] as Map<String, dynamic>?,
    );
  }
}

class ReportsService {
  // Pulls the API URL from .env, defaults to localhost if missing
  String get _baseUrl => dotenv.env['API_BASE_URL'] ?? 'http://127.0.0.1:8000';

  // Nominatim's usage policy allows ~1 request/second, no bulk/concurrent use
  static const _geocodeDelay = Duration(milliseconds: 1100);

  // Cache district lookups by rounded lat/lng so repeated fetches (refresh,
  // pull-to-retry) don't re-hit Nominatim for the same spot every time.
  final Map<String, String> _districtCache = {};

  Future<List<dynamic>> fetchDashboardRaw() async {
    final res = await http.get(Uri.parse('$_baseUrl/dashboard'));
    if (res.statusCode != 200) {
      throw Exception('Failed to load /dashboard (${res.statusCode})');
    }
    return jsonDecode(res.body) as List<dynamic>;
  }

  /// Fetches all reports from /dashboard and resolves each one's district
  /// via reverse geocoding (rate-limited to respect Nominatim's usage policy).
  Future<List<DistrictReport>> fetchAllReports() async {
    final raw = await fetchDashboardRaw();
    final reports = <DistrictReport>[];

    for (final item in raw) {
      final report = DistrictReport.fromMap(item as Map<String, dynamic>);
      if (report == null) continue;

      if (report.district == null) {
        final cacheKey =
            '${report.lat.toStringAsFixed(3)},${report.lng.toStringAsFixed(3)}';
        if (_districtCache.containsKey(cacheKey)) {
          report.district = _districtCache[cacheKey];
        } else {
          report.district = await _reverseGeocodeDistrict(
            report.lat,
            report.lng,
          );
          _districtCache[cacheKey] = report.district!;
          // Only sleep when we actually hit the network, not on cache hits.
          await Future.delayed(_geocodeDelay);
        }
      }

      reports.add(report);
    }

    return reports;
  }

  Future<String> _reverseGeocodeDistrict(double lat, double lng) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'format': 'jsonv2',
      'lat': lat.toString(),
      'lon': lng.toString(),
      'zoom': '10',
      'addressdetails': '1',
    });

    try {
      final response = await http.get(
        uri,
        headers: {'User-Agent': 'city-incident-dashboard/1.0'},
      );

      if (response.statusCode != 200) return 'Unknown area';

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final address = data['address'] as Map<String, dynamic>?;

      final name =
          address?['suburb'] ??
          address?['district'] ??
          address?['city_district'] ??
          address?['town'] ??
          address?['city'];

      return (name as String?) ?? 'Unknown area';
    } catch (_) {
      return 'Unknown area';
    }
  }

  /// Generates a fresh conversation id for a new report thread.
  static String newReportId() {
    final rand = Random();
    return '${DateTime.now().millisecondsSinceEpoch}${rand.nextInt(9999)}';
  }

  /// Sends one message to POST /report/{reportId}/message.
  /// [severityHint] is folded into the message text as a citizen-supplied
  /// hint — the backend LLM still decides the real severity itself.
  Future<ReportSubmitResult> submitReport({
    required String reportId,
    required String category,
    required String description,
    required int severityHint,
    required double lat,
    required double lng,
    String? imageBase64,
  }) async {
    final uri = Uri.parse('$_baseUrl/report/$reportId/message');

    final messageText = description.isEmpty
        ? category
        : '$category: $description';

    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'message': messageText,
        'lat': lat,
        'lng': lng,
        if (imageBase64 != null) 'image_base64': imageBase64,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to submit report (${response.statusCode})');
    }

    return ReportSubmitResult.fromMap(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }
}
