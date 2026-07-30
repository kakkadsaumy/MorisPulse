import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:geolocator/geolocator.dart';

import 'report_service.dart';

/// -----------------------------------------------------------------------
/// PICKED IMAGE (unifies camera / gallery / file-picker results)
/// -----------------------------------------------------------------------
class PickedImage {
  final String name;
  final Uint8List bytes;

  PickedImage({required this.name, required this.bytes});
}

/// -----------------------------------------------------------------------
/// DRAG & DROP FALLBACK (desktop/web) — on mobile, tapping just opens
/// the attach-options sheet passed in via [onTap].
/// -----------------------------------------------------------------------
typedef _OnDragDone = void Function(List<PlatformFile> files);

class DropTarget extends StatelessWidget {
  final Widget child;
  final _OnDragDone? onDragDone;
  final void Function(dynamic)? onDragEntered;
  final void Function(dynamic)? onDragExited;
  final VoidCallback? onTap;

  const DropTarget({
    super.key,
    required this.child,
    this.onDragDone,
    this.onDragEntered,
    this.onDragExited,
    this.onTap,
  });

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true, // Loads file bytes into memory for Web support
    );
    if (result != null && result.files.isNotEmpty) {
      onDragDone?.call(result.files);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(onTap: onTap ?? _pickFiles, child: child);
  }
}

/// -----------------------------------------------------------------------
/// DATA MODEL
/// -----------------------------------------------------------------------
enum Severity { level1, level2, level3, level4, level5 }

enum ReportStatus { open, inProgress, resolved }

extension SeverityX on Severity {
  String get label => (index + 1).toString();

  Color get color => switch (this) {
    Severity.level1 => const Color(0xFF43A047), // green
    Severity.level2 => const Color(0xFF9CCC65), // yellow-green
    Severity.level3 => const Color(0xFFFB8C00), // orange
    Severity.level4 => const Color(0xFFF4511E), // deep orange
    Severity.level5 => const Color(0xFFE53935), // red
  };
}

extension ReportStatusX on ReportStatus {
  String get display => switch (this) {
    ReportStatus.open => 'Pending',
    ReportStatus.inProgress => 'In Progress',
    ReportStatus.resolved => 'Completed',
  };
}

class Report {
  final String id;
  final String category;
  final Severity severity;
  final ReportStatus status;

  final String description;
  final String locationName;

  final double lat;
  final double lng;

  final List<String> imageUrls;

  final String? imageUrl;
  final DateTime createdAt;

  int confirmationCount;

  final List<ReportHistory> history;

  Report({
    required this.id,
    required this.category,
    required this.severity,
    required this.status,
    required this.description,
    required this.locationName,
    required this.lat,
    required this.lng,
    required this.imageUrls,
    required this.imageUrl,
    required this.createdAt,
    required this.confirmationCount,
    required this.history,
  });
}

class ReportHistory {
  final String note;
  final int severity;
  final bool imageValid;

  ReportHistory({
    required this.note,
    required this.severity,
    required this.imageValid,
  });
}

class IncidentProvider extends ChangeNotifier {
  final ReportsService _service = ReportsService();
  List<Report> _reports = [];

  String _searchQuery = '';
  Severity? _filterSeverity;
  bool isLoading = true;
  String? error;

  IncidentProvider() {
    refreshData();
  }

  String get searchQuery => _searchQuery;
  Severity? get filterSeverity => _filterSeverity;
  List<Report> get allReports => List.unmodifiable(_reports);

  List<Report> get filteredReports {
    return _reports.where((r) {
      final matchesSearch =
          _searchQuery.isEmpty ||
          r.category.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          r.locationName.toLowerCase().contains(_searchQuery.toLowerCase());
      final matchesSeverity =
          _filterSeverity == null || r.severity == _filterSeverity;
      return matchesSearch && matchesSeverity;
    }).toList();
  }

  Future<void> refreshData() async {
    isLoading = true;
    error = null;
    notifyListeners();

    try {
      final data = await _service.fetchAllReports();
      _reports = data.map((d) {
        // Map Database status to UI status
        ReportStatus mappedStatus = ReportStatus.open;
        if (d.status.toLowerCase() == 'in_progress')
          mappedStatus = ReportStatus.inProgress;
        if (d.status.toLowerCase() == 'resolved')
          mappedStatus = ReportStatus.resolved;

        // Map Database severity (int 1-5) to UI severity enum
        Severity mappedSeverity = switch (d.severity) {
          1 => Severity.level1,
          2 => Severity.level2,
          3 => Severity.level3,
          4 => Severity.level4,
          _ => Severity.level5, // covers 5 and any out-of-range high value
        };

        return Report(
          id: d.id,
          category: d.category,
          severity: mappedSeverity,
          status: mappedStatus,
          description: d.summary,
          locationName: d.district ?? "Unknown",
          lat: d.lat,
          lng: d.lng,

          imageUrls: d.imageUrl == null ? [] : [d.imageUrl!],
          imageUrl: d.imageUrl,

          confirmationCount: d.confirmations,
          createdAt: d.createdAt,

          history: d.history
              .map(
                (h) => ReportHistory(
                  note: h.note,
                  severity: h.severity,
                  imageValid: h.imageValid,
                ),
              )
              .toList(),
        );
      }).toList();
    } catch (e) {
      debugPrint('Error fetching reports: $e');
      error = e.toString();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  void addReport(Report report) {
    _reports.insert(0, report);
    notifyListeners();
  }

  void setSearchQuery(String value) {
    _searchQuery = value;
    notifyListeners();
  }

  void setFilterSeverity(Severity? value) {
    _filterSeverity = value;
    notifyListeners();
  }

  void incrementConfirmation(String id) {
    final index = _reports.indexWhere((r) => r.id == id);
    if (index != -1) {
      _reports[index].confirmationCount++;
      notifyListeners();
    }
  }
}

void start() {
  runApp(
    ChangeNotifierProvider<IncidentProvider>(
      create: (_) => IncidentProvider(),
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        // Comfortable minimum tap target size + Material 3 for the
        // NavigationBar used in the mobile layout below.
        theme: ThemeData(useMaterial3: true, visualDensity: VisualDensity.standard),
        home: const DashboardScreen(),
      ),
    ),
  );
}

/// -----------------------------------------------------------------------
/// DASHBOARD SCREEN
/// Responsive: side-by-side map + list on wide (tablet/desktop/web)
/// screens, tabbed single-pane view with a bottom nav bar on phones.
/// -----------------------------------------------------------------------
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  static const _mobileBreakpoint = 700.0;
  int _mobileTabIndex = 0; // 0 = Map, 1 = List

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < _mobileBreakpoint;

    return Scaffold(
      appBar: AppBar(
        title: const Text('City Incident Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Refresh Data',
            icon: const Icon(Icons.refresh),
            onPressed: () => context.read<IncidentProvider>().refreshData(),
          ),
          // On mobile the FAB below handles "new report", so we drop the
          // extra AppBar button to keep the bar from getting crowded.
          if (!isMobile)
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NewReportScreen()),
              ),
              child: const Text(
                'Register',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
      body: isMobile
          ? IndexedStack(
              index: _mobileTabIndex,
              children: const [MapViewWidget(), IncidentListScreen()],
            )
          : const Row(
              children: [
                Expanded(flex: 2, child: MapViewWidget()),
                VerticalDivider(width: 1),
                Expanded(flex: 2, child: IncidentListScreen()),
              ],
            ),
      bottomNavigationBar: isMobile
          ? NavigationBar(
              selectedIndex: _mobileTabIndex,
              onDestinationSelected: (i) =>
                  setState(() => _mobileTabIndex = i),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.map_outlined),
                  selectedIcon: Icon(Icons.map),
                  label: 'Map',
                ),
                NavigationDestination(
                  icon: Icon(Icons.list_alt_outlined),
                  selectedIcon: Icon(Icons.list_alt),
                  label: 'List',
                ),
              ],
            )
          : null,
      floatingActionButton: isMobile
          ? FloatingActionButton.extended(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NewReportScreen()),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Report'),
            )
          : null,
    );
  }
}

/// -----------------------------------------------------------------------
/// NEW REPORT SCREEN
/// -----------------------------------------------------------------------
class NewReportScreen extends StatefulWidget {
  const NewReportScreen({super.key});

  @override
  State<NewReportScreen> createState() => _NewReportScreenState();
}

class _NewReportScreenState extends State<NewReportScreen> {
  final _catController = TextEditingController();
  final _descController = TextEditingController();
  Severity _selectedSeverity = Severity.level1;

  final String _reportId = ReportsService.newReportId();

  final ImagePicker _picker = ImagePicker();
  final MapController _mapController = MapController();

  final List<PickedImage> _uploadedFiles = [];
  bool _isDragging = false;
  bool _isSubmitting = false;
  bool _isLocating = false;
  LatLng? _pinnedLocation;

  @override
  void dispose() {
    _catController.dispose();
    _descController.dispose();
    super.dispose();
  }

  void _addPickedImage(PickedImage img) {
    if (_uploadedFiles.any((f) => f.name == img.name)) return;
    setState(() => _uploadedFiles.add(img));
  }

  Future<void> _pickFromCamera() async {
    try {
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1600,
        imageQuality: 85,
      );
      if (photo != null) {
        final bytes = await photo.readAsBytes();
        _addPickedImage(PickedImage(name: photo.name, bytes: bytes));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Camera unavailable: $e')));
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final List<XFile> images = await _picker.pickMultiImage(
        maxWidth: 1600,
        imageQuality: 85,
      );
      for (final img in images) {
        final bytes = await img.readAsBytes();
        _addPickedImage(PickedImage(name: img.name, bytes: bytes));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open gallery: $e')));
    }
  }

  Future<void> _browseFiles() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );

    if (result != null && result.files.isNotEmpty) {
      for (final file in result.files) {
        if (file.bytes != null) {
          _addPickedImage(PickedImage(name: file.name, bytes: file.bytes!));
        }
      }
    }
  }

  Future<void> _showAttachOptions() async {
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take Photo'),
              onTap: () {
                Navigator.pop(ctx);
                _pickFromCamera();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from Gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _pickFromGallery();
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('Browse Files'),
              onTap: () {
                Navigator.pop(ctx);
                _browseFiles();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _removeImage(int index) {
    setState(() {
      _uploadedFiles.removeAt(index);
    });
  }

  String? _firstImageAsBase64() {
    if (_uploadedFiles.isEmpty) return null;
    try {
      return base64Encode(_uploadedFiles.first.bytes);
    } catch (_) {
      return null;
    }
  }

  Future<void> _useCurrentLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Turn on location services to use this')),
      );
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location permission denied')),
        );
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Location permission is permanently denied. Enable it in Settings.',
          ),
        ),
      );
      return;
    }

    setState(() => _isLocating = true);
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      final point = LatLng(pos.latitude, pos.longitude);
      setState(() => _pinnedLocation = point);
      _mapController.move(point, 15);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not get location: $e')));
    } finally {
      if (mounted) setState(() => _isLocating = false);
    }
  }

  Future<void> _submit() async {
    if (_pinnedLocation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tap the map to set a location')),
      );
      return;
    }

    // Dismiss the keyboard before submitting so the snackbar/nav pop
    // below isn't fighting a resizing keyboard on small screens.
    FocusScope.of(context).unfocus();
    setState(() => _isSubmitting = true);

    try {
      final imageBase64 = _firstImageAsBase64();
      final result = await ReportsService().submitReport(
        reportId: _reportId,
        category: _catController.text.isEmpty ? 'General' : _catController.text,
        description: _descController.text,
        severityHint: _selectedSeverity.index + 1,
        lat: _pinnedLocation!.latitude,
        lng: _pinnedLocation!.longitude,
        imageBase64: imageBase64,
      );

      if (!mounted) return;

      switch (result.type) {
        case 'submitted':
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Report submitted')));
          context.read<IncidentProvider>().refreshData();
          Navigator.pop(context);
          break;
        case 'duplicate':
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Matches an existing report: '
                '${result.report?['summary'] ?? 'see dashboard'}',
              ),
            ),
          );
          Navigator.pop(context);
          break;
        case 'question':
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result.question ?? 'Need more info')),
          );
          break;
        case 'error':
        default:
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(result.message ?? 'Something went wrong')),
          );
          break;
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to submit: $e')));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('File New Report')),
      // resizeToAvoidBottomInset (on by default) keeps the form scrollable
      // above the keyboard on phones.
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _catController,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Title'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _descController,
              maxLines: 3,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: 'Description'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<Severity>(
              value: _selectedSeverity,
              items: Severity.values
                  .map(
                    (s) => DropdownMenuItem(
                      value: s,
                      child: Text('Level ${s.label}'),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _selectedSeverity = v!),
              decoration: const InputDecoration(labelText: 'Severity'),
            ),
            const SizedBox(height: 24),
            const Text(
              'Attach Images',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            DropTarget(
              onTap: _showAttachOptions,
              onDragEntered: (_) => setState(() => _isDragging = true),
              onDragExited: (_) => setState(() => _isDragging = false),
              onDragDone: (files) {
                for (final file in files) {
                  if (file.bytes != null) {
                    _addPickedImage(
                      PickedImage(name: file.name, bytes: file.bytes!),
                    );
                  }
                }
                setState(() => _isDragging = false);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                height: 140,
                decoration: BoxDecoration(
                  color: _isDragging
                      ? Theme.of(context).primaryColor.withOpacity(0.1)
                      : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _isDragging
                        ? Theme.of(context).primaryColor
                        : Colors.grey.shade400,
                    width: 2,
                    style: BorderStyle.solid,
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        kIsWeb
                            ? Icons.cloud_upload_outlined
                            : Icons.add_photo_alternate_outlined,
                        size: 40,
                        color: _isDragging
                            ? Theme.of(context).primaryColor
                            : Colors.grey.shade600,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        kIsWeb
                            ? 'Drag & drop images here, or'
                            : 'Take a photo or choose from your gallery',
                        style: const TextStyle(color: Colors.grey),
                      ),
                      const SizedBox(height: 4),
                      OutlinedButton.icon(
                        onPressed: _showAttachOptions,
                        icon: Icon(
                          kIsWeb ? Icons.folder_open : Icons.add_a_photo,
                          size: 18,
                        ),
                        label: Text(kIsWeb ? 'Browse Files' : 'Add Photos'),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            if (_uploadedFiles.isNotEmpty) ...[
              const SizedBox(height: 16),
              SizedBox(
                height: 90,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _uploadedFiles.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final file = _uploadedFiles[index];
                    return Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory(
                            file.bytes,
                            width: 90,
                            height: 90,
                            fit: BoxFit.cover,
                          ),
                        ),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: GestureDetector(
                            onTap: () => _removeImage(index),
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close,
                                size: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],

            const SizedBox(height: 24),

            Row(
              children: [
                const Text(
                  'Location',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _isLocating ? null : _useCurrentLocation,
                  icon: _isLocating
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.my_location, size: 18),
                  label: const Text('Use my location'),
                ),
              ],
            ),
            Text(
              _pinnedLocation == null
                  ? 'Tap the map below to drop a pin'
                  : 'Selected: ${_pinnedLocation!.latitude.toStringAsFixed(4)}, ${_pinnedLocation!.longitude.toStringAsFixed(4)}',
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 220,
                child: FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: const LatLng(-20.25, 57.5),
                    initialZoom: 10,
                    onTap: (tapPosition, point) =>
                        setState(() => _pinnedLocation = point),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    ),
                    if (_pinnedLocation != null)
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _pinnedLocation!,
                            child: const Icon(
                              Icons.location_pin,
                              size: 36,
                              color: Colors.redAccent,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _isSubmitting ? null : _submit,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _isSubmitting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Submit Report'),
            ),
          ],
        ),
      ),
    );
  }
}

/// -----------------------------------------------------------------------
/// MAP VIEW WIDGET
/// -----------------------------------------------------------------------
class MapViewWidget extends StatelessWidget {
  const MapViewWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<IncidentProvider>(
      builder: (context, provider, _) {
        final reports = provider.filteredReports;

        if (provider.isLoading && reports.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        return FlutterMap(
          options: const MapOptions(
            initialCenter: LatLng(-20.25, 57.5),
            initialZoom: 11,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            ),
            MarkerLayer(
              markers: reports
                  .map(
                    (r) => Marker(
                      point: LatLng(r.lat, r.lng),
                      child: Icon(
                        Icons.location_pin,
                        size: 30,
                        color: r.severity.color,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        );
      },
    );
  }
}

/// -----------------------------------------------------------------------
/// INCIDENT LIST SCREEN (As seen in the dashboard rows)
/// -----------------------------------------------------------------------
class IncidentListScreen extends StatelessWidget {
  const IncidentListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: TextField(
            onChanged: (v) =>
                context.read<IncidentProvider>().setSearchQuery(v),
            decoration: const InputDecoration(
              hintText: 'Search...',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: Consumer<IncidentProvider>(
            builder: (context, provider, _) {
              if (provider.isLoading && provider.allReports.isEmpty) {
                return const Center(child: CircularProgressIndicator());
              }

              if (provider.error != null && provider.allReports.isEmpty) {
                return RefreshIndicator(
                  onRefresh: provider.refreshData,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.error_outline,
                              color: Colors.red,
                              size: 40,
                            ),
                            const SizedBox(height: 12),
                            SelectableText(
                              'Failed to load reports:\n${provider.error}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.red),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              'Pull down to retry',
                              style: TextStyle(color: Colors.grey),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }

              if (provider.filteredReports.isEmpty) {
                return RefreshIndicator(
                  onRefresh: provider.refreshData,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: const [
                      Padding(
                        padding: EdgeInsets.only(top: 80),
                        child: Center(child: Text('No reports found.')),
                      ),
                    ],
                  ),
                );
              }

              // Pull-to-refresh is the standard mobile pattern for
              // reloading a list — much more natural on a phone than
              // relying on the AppBar refresh icon alone.
              return RefreshIndicator(
                onRefresh: provider.refreshData,
                child: ListView.separated(
                  physics: const AlwaysScrollableScrollPhysics(),
                  itemCount: provider.filteredReports.length,
                  separatorBuilder: (_, __) => const Divider(),
                  itemBuilder: (context, i) {
                    final r = provider.filteredReports[i];
                    return ListTile(
                      title: Text(
                        r.category,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        '${r.locationName}\nStatus: ${r.status.display}',
                      ),
                      isThreeLine: true,
                      trailing: Chip(
                        label: Text('Lvl ${r.severity.label}'),
                        backgroundColor: r.severity.color.withOpacity(0.2),
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ReportDetailScreen(report: r),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// -----------------------------------------------------------------------
/// REPORT DETAIL SCREEN
/// -----------------------------------------------------------------------
class ReportDetailScreen extends StatelessWidget {
  final Report report;
  const ReportDetailScreen({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Incident ${report.category}')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              report.category,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 20),
            ListTile(
              title: const Text('Status'),
              trailing: Text(
                report.status.display,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              title: const Text('Severity'),
              trailing: Text(
                'Level ${report.severity.label}',
                style: TextStyle(
                  color: report.severity.color,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Text('Summary', style: Theme.of(context).textTheme.titleLarge),
            Text(report.description),
            const SizedBox(height: 16),
            if (report.imageUrls.isNotEmpty) ...[
              Text(
                'Attached Images',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 100,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: report.imageUrls.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, i) {
                    final path = report.imageUrls[i];
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: kIsWeb || path.startsWith('http')
                          ? Image.network(
                              path,
                              width: 100,
                              height: 100,
                              fit: BoxFit.cover,
                            )
                          : Image.file(
                              File(path),
                              width: 100,
                              height: 100,
                              fit: BoxFit.cover,
                            ),
                    );
                  },
                ),
              ),
            ],
            const Divider(height: 40),
            Consumer<IncidentProvider>(
              builder: (context, provider, _) => Row(
                children: [
                  Text('Confirmations: ${report.confirmationCount}'),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: () => provider.incrementConfirmation(report.id),
                    icon: const Icon(Icons.thumb_up),
                    label: const Text('Confirm'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}