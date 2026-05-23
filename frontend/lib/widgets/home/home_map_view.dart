import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../core/app_colors.dart';
import '../../models/map_issue.dart';
import '../../models/place_marker.dart';
import '../map_marker.dart';
import '../map_place_marker.dart';
import '../search_bar_widget.dart';
import 'current_location_marker.dart';

class HomeMapView extends StatelessWidget {
  final MapController mapController;
  final List<MapIssue> mapIssues;
  final List<PlaceMarker> placeMarkers;
  final LatLng? currentLocation;
  final VoidCallback onLogout;
  final VoidCallback onRecenter;
  final VoidCallback onShowAddReport;
  final VoidCallback onShowGoTo;
  final VoidCallback onClearPlaces;
  final ValueChanged<MapIssue> onTapIssue;
  final ValueChanged<PlaceMarker> onTapPlace;
  final List<LatLng> pathPoints;

  const HomeMapView({
    super.key,
    required this.mapController,
    required this.mapIssues,
    required this.placeMarkers,
    required this.currentLocation,
    required this.onLogout,
    required this.onRecenter,
    required this.onShowAddReport,
    required this.onShowGoTo,
    required this.onClearPlaces,
    required this.onTapIssue,
    required this.onTapPlace,
    required this.pathPoints,
  });

  @override
  Widget build(BuildContext context) {
    final showingPlaces = placeMarkers.isNotEmpty;

    return Expanded(
      child: Stack(
        children: [
          // ── map ──────────────────────────────────────────────────────────
          FlutterMap(
            mapController: mapController,
            options: const MapOptions(
              initialCenter: LatLng(31.24, 36.51),
              initialZoom: 7.5,
              minZoom: 6,
              maxZoom: 18,
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.roadna',
              ),

              // route polyline
              if (pathPoints.isNotEmpty)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: pathPoints,
                      strokeWidth: 8,
                      color: AppColors.primary,
                    ),
                  ],
                ),

              // road-issue markers
              MarkerLayer(
                markers: [
                  ...mapIssues.map(
                    (issue) => Marker(
                      point: issue.position,
                      width: 40,
                      height: 40,
                      child: MapMarker(
                        emoji: issue.emoji,
                        color: issue.color,
                        onTap: () => onTapIssue(issue),
                      ),
                    ),
                  ),
                  if (currentLocation != null)
                    Marker(
                      point: currentLocation!,
                      width: 30,
                      height: 30,
                      child: const CurrentLocationMarker(),
                    ),
                ],
              ),

              // place markers (shown after Go-To category is selected)
              if (showingPlaces)
                MarkerLayer(
                  markers: placeMarkers
                      .map(
                        (p) => Marker(
                          point: LatLng(p.lat, p.lon),
                          width: 50,
                          height: 50,
                          // bottomCenter → pin tail points at the coordinate
                          alignment: Alignment.bottomCenter,
                          child: MapPlaceMarker(
                            emoji: p.category.emoji,
                            onTap: () => onTapPlace(p),
                          ),
                        ),
                      )
                      .toList(),
                ),
            ],
          ),

          // ── top bar ───────────────────────────────────────────────────────
          SearchBarWidget(onLogout: onLogout),

          // ── "Clear places" chip — appears while place pins are visible ────
          if (showingPlaces)
            Positioned(
              left: 14,
              bottom: 148,
              child: GestureDetector(
                onTap: onClearPlaces,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                        color: AppColors.primary.withOpacity(0.4)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x22000000),
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        placeMarkers.first.category.emoji,
                        style: const TextStyle(fontSize: 14),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${placeMarkers.length} places',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textDark,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.close,
                          size: 15, color: AppColors.textGrey),
                    ],
                  ),
                ),
              ),
            ),

          // ── Go-To button ──────────────────────────────────────────────────
          Positioned(
            left: 14,
            bottom: 96,
            child: ElevatedButton.icon(
              onPressed: onShowGoTo,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.white,
                foregroundColor: AppColors.greenDark,
                elevation: 3,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                padding: const EdgeInsets.symmetric(
                    horizontal: 18, vertical: 11),
              ),
              icon: const Icon(Icons.navigation_outlined, size: 16),
              label: const Text(
                'Go To',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),

          // ── recenter button ───────────────────────────────────────────────
          Positioned(
            right: 14,
            bottom: 150,
            child: Material(
              color: AppColors.white,
              shape: const CircleBorder(),
              elevation: 3,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onRecenter,
                child: const SizedBox(
                  width: 42,
                  height: 42,
                  child: Icon(Icons.my_location,
                      color: AppColors.textGrey),
                ),
              ),
            ),
          ),

          // ── add-report FAB ────────────────────────────────────────────────
          Positioned(
            right: 14,
            bottom: 86,
            child: FloatingActionButton(
              backgroundColor: AppColors.green,
              onPressed: onShowAddReport,
              child: const Icon(Icons.add, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
