import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/app_colors.dart';
import '../data/map_dummy_data.dart';
import '../models/app_category.dart';
import '../models/map_issue.dart';
import '../models/path_node.dart';
import '../models/place_marker.dart';
import 'package:image_picker/image_picker.dart';
import '../services/auth_service.dart';
import '../services/report_service.dart';
import '../services/user_service.dart';
import '../services/routing_service.dart';
import '../widgets/bottom_nav_bar.dart';
import '../widgets/home/add_report_sheet.dart';
import '../widgets/home/go_to_sheet.dart';
import '../widgets/home/home_map_view.dart';
import '../widgets/home/issue_details_sheet.dart';
import '../widgets/home/place_details_sheet.dart';
import '../widgets/home/report_form_sheet.dart';
import '../widgets/home/success_dialog.dart';
import 'profile_screen.dart';
import 'reports_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AuthService _authService = AuthService();
  final ReportService _reportService = ReportService();
  final RoutingService _routingService = RoutingService();
  final UserService _userService = UserService();

  int _selectedNavIndex = 0;

  final MapController _mapController = MapController();
  LatLng? _currentLocation;

  late List<MapIssue> _mapIssues;
  List<PlaceMarker> _placeMarkers = [];
  List<LatLng> _pathPoints = [];

  final Set<String> _votedIssueIds = {};
  bool _isLoading = false;

  /// ID of the currently logged-in user — used to block self-voting.
  int? _currentUserId;

  @override
  void initState() {
    super.initState();
    _mapIssues = List<MapIssue>.from(initialIssues);
    _requestPermissionsThenLoad();
    _loadReports();
    _loadCurrentUserId();
  }

  /// Ask for location + camera + storage all at once on first launch.
  Future<void> _requestPermissionsThenLoad() async {
    final statuses = await [
      Permission.locationWhenInUse,
      Permission.camera,
      Permission.photos,         // READ_MEDIA_IMAGES on Android 13+
      Permission.storage,        // READ_EXTERNAL_STORAGE on Android ≤12
    ].request();

    final locationGranted =
        statuses[Permission.locationWhenInUse] == PermissionStatus.granted;

    if (locationGranted) {
      _loadLocation();
    } else {
      // Permanently denied → direct user to app settings
      if (statuses[Permission.locationWhenInUse] ==
          PermissionStatus.permanentlyDenied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                  'Location permission is required. Enable it in App Settings.'),
              action: SnackBarAction(
                label: 'Settings',
                onPressed: openAppSettings,
              ),
              duration: const Duration(seconds: 6),
            ),
          );
        }
      }
    }
  }

  Future<void> _loadCurrentUserId() async {
    final result = await _userService.getProfile();
    if (!mounted) return;
    if (result['success'] == true) {
      final data = result['data'] as Map<String, dynamic>?;
      if (data != null) {
        setState(() {
          _currentUserId = (data['id'] as num?)?.toInt();
        });
      }
    }
  }

  void _setLoading(bool v) {
    if (mounted) setState(() => _isLoading = v);
  }

  String _formatDistance(double meters) => meters < 1000
      ? '${meters.round()} m away'
      : '${(meters / 1000).toStringAsFixed(1)} km away';

  Future<void> _loadLocation() async {
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) return;

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        _snack('Please enable location services (GPS) on your device.');
      }
      return;
    }

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (!mounted) return;
      setState(() => _currentLocation = LatLng(pos.latitude, pos.longitude));
      _mapController.move(_currentLocation!, 16);
    } on TimeoutException {
      if (!mounted) return;
      _snack('Could not get location. Make sure GPS is enabled and try again.');
    } catch (_) {
      if (!mounted) return;
      _snack('Could not get location. Make sure GPS is enabled and try again.');
    }
  }

  void _recenterMap() {
    if (_currentLocation != null) _mapController.move(_currentLocation!, 16);
  }

  Future<void> _loadReports() async {
    final result = await _reportService.getAllReports();
    if (!mounted) return;
    if (result['success'] == true) {
      final list = result['data'] as List<dynamic>;
      // Always update — even an empty list should clear dummy data
      setState(() {
        _mapIssues = list
            .map((j) => MapIssue.fromJson(j as Map<String, dynamic>))
            .toList();
      });
    }
  }

  Future<void> _logout() async {
    await _authService.logout();
    if (mounted) {
      Navigator.pushNamedAndRemoveUntil(context, '/login', (_) => false);
    }
  }

  void _showIssueSheet(MapIssue issue) {
    final isOwnReport = _currentUserId != null &&
        issue.ownerId != null &&
        issue.ownerId == _currentUserId;

    showIssueDetailsSheet(
      context: context,
      issue: issue,
      isOwnReport: isOwnReport,
      alreadyVoted: _votedIssueIds.contains(issue.id),
      onVoteStillThere: () async {
        final result = await _reportService.voteReport(
          reportId: issue.id,
          voteType: 'Still',
        );
        if (result['success'] == true) {
          setState(() {
            _votedIssueIds.add(issue.id);
            final idx = _mapIssues.indexWhere((e) => e.id == issue.id);
            if (idx != -1) {
              _mapIssues[idx] = _mapIssues[idx].copyWith(
                stillThereCount: _mapIssues[idx].stillThereCount + 1,
                isVoted: true,
              );
            }
          });
          return null; // null = success
        } else {
          return result['message'] as String? ?? 'Could not submit vote.';
        }
      },
      onVoteFixed: () async {
        final result = await _reportService.voteReport(
          reportId: issue.id,
          voteType: 'Fixed',
        );
        if (result['success'] == true) {
          setState(() {
            _votedIssueIds.add(issue.id);
            final idx = _mapIssues.indexWhere((e) => e.id == issue.id);
            if (idx != -1) {
              _mapIssues[idx] = _mapIssues[idx].copyWith(
                fixedCount: _mapIssues[idx].fixedCount + 1,
                isVoted: true,
              );
            }
          });
          return null; // null = success
        } else {
          return result['message'] as String? ?? 'Could not submit vote.';
        }
      },
    );
  }

  void _showAddReportSheet() {
    showAddReportSheet(
      context: context,
      onCategorySelected: (AppCategory cat) => _showReportForm(cat),
    );
  }

  void _showReportForm(AppCategory category) {
    showReportFormSheet(
      context: context,
      category: category,
      onSubmit: (String? subProblem, String? description, String? note, List<XFile> images) =>
          _submitReport(
            category: category,
            subProblem: subProblem,
            description: description,
            note: note,
            images: images,
          ),
    );
  }

  Future<void> _submitReport({
    required AppCategory category,
    String? subProblem,
    String? description,
    String? note,
    List<XFile> images = const [],
  }) async {
    if (_currentLocation == null) {
      _snack('Location unavailable. Allow location access first.');
      return;
    }

    final result = await _reportService.createReport(
      category: category.backendValue,
      subProblem: subProblem,
      description: description,
      note: note,
      lat: _currentLocation!.latitude,
      lon: _currentLocation!.longitude,
      images: images.isEmpty ? null : images,
    );

    if (!mounted) return;

    if (result['success'] == true) {
      _mapController.move(_currentLocation!, 16);
      // Reload all reports from server so the real marker (with correct ID)
      // replaces any stale data — avoids a fake local ID that would 404 on vote.
      _loadReports();

      showSuccessDialog(
        context: context,
        title: 'Report Submitted!',
        message:
            'Your ${category.displayName} report has been pinned at your current location.',
      );
    } else {
      _snack(result['message'] as String? ?? 'Could not submit report.');
    }
  }

  void _showGoToSheet() {
    showGoToSheet(
      context: context,
      onCategorySelected: (AppCategory category) async {
        if (_currentLocation == null) {
          _snack('Location unavailable. Allow location access.');
          return;
        }

        _setLoading(true);

        final result = await _routingService.getNearbyPlaces(
          lat: _currentLocation!.latitude,
          lon: _currentLocation!.longitude,
          categoryBackendValue: category.backendValue,
        );

        _setLoading(false);
        if (!mounted) return;

        final rawList = result['data'] as List<dynamic>?;
        if (result['success'] != true || rawList == null || rawList.isEmpty) {
          _snack(result['message'] as String? ??
              'No ${category.displayName} found nearby.');
          return;
        }

        final places = rawList
            .map((j) =>
            PlaceMarker.fromH3Json(j as Map<String, dynamic>, category))
            .toList();

        setState(() {
          _placeMarkers = places;
          _pathPoints = [];
        });

        _mapController.move(
          LatLng(places.first.lat, places.first.lon),
          14,
        );
      },
    );
  }

  void _clearPlaces() {
    setState(() {
      _placeMarkers = [];
      _pathPoints = [];
    });
  }

  void _onTapPlace(PlaceMarker place) {
    if (_currentLocation == null) {
      _snack('Location unavailable.');
      return;
    }

    final dist = const Distance()(
      _currentLocation!,
      LatLng(place.lat, place.lon),
    );

    showPlaceDetailsSheet(
      context: context,
      place: place,
      distanceStr: _formatDistance(dist),
      onRoute: () => _routeToPlace(place),
    );
  }

  Future<void> _routeToPlace(PlaceMarker place) async {
    if (_currentLocation == null) return;

    _setLoading(true);

    final result = await _routingService.getRoute(
      lat1: _currentLocation!.latitude,
      lon1: _currentLocation!.longitude,
      lat2: place.lat,
      lon2: place.lon,
    );

    _setLoading(false);
    if (!mounted) return;

    if (result['success'] == true) {
      final data = result['data'] as Map<String, dynamic>;
      final rawNodes = data['pathNodes'] as List<dynamic>;
      final nodes = rawNodes
          .map((n) => PathNode.fromJson(n as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.order.compareTo(b.order));

      setState(() {
        _pathPoints =
            nodes.map((n) => LatLng(n.latitude, n.longitude)).toList();
        _placeMarkers = [];
      });
      _mapController.move(_currentLocation!, 15);

      showSuccessDialog(
        context: context,
        title: 'Navigation Started',
        message: 'Routing to ${place.name}. Follow the directions on the map.',
      );
    } else {
      _snack(result['message'] as String? ?? 'Could not calculate route.');
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _buildBody() {
    if (_selectedNavIndex == 2) return const ProfileScreen();

    if (_selectedNavIndex == 1) {
      return ReportsScreen();    }

    return HomeMapView(
      mapController: _mapController,
      mapIssues: _mapIssues,
      placeMarkers: _placeMarkers,
      currentLocation: _currentLocation,
      onLogout: _logout,
      onRecenter: _recenterMap,
      onShowAddReport: _showAddReportSheet,
      onShowGoTo: _showGoToSheet,
      onClearPlaces: _clearPlaces,
      onTapIssue: _showIssueSheet,
      onTapPlace: _onTapPlace,
      pathPoints: _pathPoints,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          backgroundColor: AppColors.white,
          body: SafeArea(
            child: Column(
              children: [
                Expanded(child: _buildBody()),
                HomeBottomNavBar(
                  selectedIndex: _selectedNavIndex,
                  onTap: (i) => setState(() => _selectedNavIndex = i),
                ),
              ],
            ),
          ),
        ),
        if (_isLoading)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0x55000000),
              child: Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              ),
            ),
          ),
      ],
    );
  }
}