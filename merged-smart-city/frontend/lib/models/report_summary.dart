import 'package:latlong2/latlong.dart';

class ReportSummary {
  final double lat;
  final double lng;
  final int count;

  const ReportSummary({
    required this.lat,
    required this.lng,
    required this.count,
  });

  LatLng get position => LatLng(lat, lng);

  factory ReportSummary.fromJson(Map<String, dynamic> json) => ReportSummary(
        lat: (json['lat'] as num).toDouble(),
        lng: (json['lng'] as num).toDouble(),
        count: (json['count'] as num?)?.toInt() ?? 0,
      );
}
