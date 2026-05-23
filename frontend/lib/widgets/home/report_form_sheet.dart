import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/app_colors.dart';
import '../../data/sub_problems.dart';
import '../../models/app_category.dart';
import '../sheet_handle.dart';

void showReportFormSheet({
  required BuildContext context,
  required AppCategory category,
  required void Function(
    String? subProblem,
    String? description,
    String? note,
    List<XFile> images,
  ) onSubmit,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ReportFormSheet(category: category, onSubmit: onSubmit),
  );
}

// ---------------------------------------------------------------------------
// Stateful sheet widget
// ---------------------------------------------------------------------------
class _ReportFormSheet extends StatefulWidget {
  final AppCategory category;
  final void Function(String?, String?, String?, List<XFile>) onSubmit;

  const _ReportFormSheet({required this.category, required this.onSubmit});

  @override
  State<_ReportFormSheet> createState() => _ReportFormSheetState();
}

class _ReportFormSheetState extends State<_ReportFormSheet> {
  /// null    = user hasn't picked yet
  /// 'other' = user picked "Other (not in list)"
  /// else    = exact sub-problem text
  String? _selectedSubProblem;

  final _descController = TextEditingController();
  final _noteController = TextEditingController();
  // XFile list is passed to onSubmit; bytes are cached for display (web-safe).
  final List<XFile> _selectedImages = [];
  final List<Uint8List> _selectedBytes = [];
  final ImagePicker _picker = ImagePicker();

  /// Shown as a red inline banner when validation fails.
  String? _errorMessage;

  bool get _isOtherCategory => widget.category.backendValue == 'other';
  bool get _isOtherPath => _isOtherCategory || _selectedSubProblem == 'other';
  List<String> get _options => subProblems[widget.category.backendValue] ?? [];

  @override
  void dispose() {
    _descController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  // ── Camera ─────────────────────────────────────────────────────────────────
  Future<void> _takePhoto() async {
    final photo = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 75,
    );
    if (photo == null || !mounted) return;
    // Read bytes once here — Image.memory is cross-platform (web + mobile).
    final bytes = await photo.readAsBytes();
    if (!mounted) return;
    setState(() {
      if (_selectedImages.length < 5) {
        _selectedImages.add(photo);
        _selectedBytes.add(bytes);
        _clearError();
      }
    });
  }

  // ── Validation & Submit ────────────────────────────────────────────────────
  void _submit() {
    if (!_isOtherCategory && _selectedSubProblem == null) {
      _setError('Please select an issue option.');
      return;
    }
    if (_isOtherPath && _descController.text.trim().isEmpty) {
      _setError('Please describe the issue before submitting.');
      return;
    }
    if (_selectedImages.isEmpty) {
      _setError('At least one photo is required before submitting.');
      return;
    }

    Navigator.pop(context);
    widget.onSubmit(
      _isOtherPath ? null : _selectedSubProblem,
      _isOtherPath ? _descController.text.trim() : null,
      (!_isOtherPath && _noteController.text.trim().isNotEmpty)
          ? _noteController.text.trim()
          : null,
      List.from(_selectedImages),
    );
  }

  void _setError(String msg) => setState(() => _errorMessage = msg);
  void _clearError() => setState(() => _errorMessage = null);

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 24),
      decoration: const BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          18,
          12,
          18,
          MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Drag handle ───────────────────────────────────────────────
              const SheetHandle(),
              const SizedBox(height: 14),

              // ── Header row (title + close button) ─────────────────────────
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.category.emoji}  ${widget.category.displayName}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Colors.black,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close,
                          size: 20, color: Colors.black54),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // ── Sub-problem list OR Description (other category) ───────────
              if (_isOtherCategory) ...[
                _sectionLabel('Describe the issue *'),
                const SizedBox(height: 8),
                _descriptionField(),
              ] else ...[
                _sectionLabel("What's the specific issue? *"),
                const SizedBox(height: 8),
                _subProblemList(),
              ],

              // ── After sub-problem selected ────────────────────────────────
              if (!_isOtherCategory && _selectedSubProblem != null) ...[
                const SizedBox(height: 20),
                if (_isOtherPath) ...[
                  _sectionLabel('Describe the issue *'),
                  const SizedBox(height: 8),
                  _descriptionField(),
                ] else ...[
                  _sectionLabel('Note for staff (optional)  🔒'),
                  const SizedBox(height: 4),
                  Text(
                    'Not reviewed by AI — only visible to staff/admin',
                    style: TextStyle(
                        fontSize: 11, color: Colors.grey.shade500),
                  ),
                  const SizedBox(height: 8),
                  _noteField(),
                ],
              ],

              const SizedBox(height: 20),

              // ── Photos ────────────────────────────────────────────────────
              _sectionLabel('Photos (required, up to 5)'),
              const SizedBox(height: 8),
              if (_selectedImages.length < 5)
                _cameraButton()
              else
                _photoLimitBanner(),
              if (_selectedImages.isNotEmpty) ...[
                const SizedBox(height: 12),
                _thumbnailStrip(),
                const SizedBox(height: 4),
                Text(
                  '${_selectedImages.length}/5 photo(s) selected',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textGrey),
                ),
              ],

              const SizedBox(height: 14),
              const Row(
                children: [
                  Icon(Icons.location_on, size: 16, color: AppColors.green),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Report will be pinned at your current location',
                      style: TextStyle(
                          fontSize: 13, color: AppColors.textGrey),
                    ),
                  ),
                ],
              ),

              // ── Inline error banner ───────────────────────────────────────
              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF0F0),
                    borderRadius: BorderRadius.circular(14),
                    border:
                        Border.all(color: const Color(0xFFFFCDD2), width: 1.5),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.error_outline,
                          color: Color(0xFFC62828), size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: const TextStyle(
                            fontSize: 13,
                            color: Color(0xFFC62828),
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      GestureDetector(
                        onTap: _clearError,
                        child: const Icon(Icons.close,
                            size: 16, color: Color(0xFFC62828)),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 16),

              // ── Submit button ─────────────────────────────────────────────
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    'Submit Report',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Helper widgets ─────────────────────────────────────────────────────────

  Widget _sectionLabel(String text) => Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Colors.grey.shade800,
        ),
      );

  Widget _subProblemList() {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.black12),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          ..._options.asMap().entries.map((entry) {
            final i = entry.key;
            final option = entry.value;
            return Column(
              children: [
                _radioTile(label: option, value: option),
                if (i < _options.length - 1)
                  const Divider(
                      height: 1, indent: 44, color: Colors.black12),
              ],
            );
          }),
          const Divider(height: 1, color: Colors.black12),
          _radioTile(
            label: 'Other (not in list)',
            value: 'other',
            isOther: true,
          ),
        ],
      ),
    );
  }

  Widget _radioTile({
    required String label,
    required String value,
    bool isOther = false,
  }) {
    final isSelected = _selectedSubProblem == value;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        setState(() {
          _selectedSubProblem = value;
          if (!isOther) _descController.clear();
          _clearError();
        });
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: isSelected ? AppColors.green : Colors.grey,
            ),
            const SizedBox(width: 10),
            if (isOther) ...[
              Icon(Icons.help_outline,
                  size: 16, color: Colors.grey.shade500),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  color: isOther ? Colors.grey.shade600 : Colors.black87,
                  fontStyle:
                      isOther ? FontStyle.italic : FontStyle.normal,
                  fontWeight:
                      isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _descriptionField() => TextField(
        controller: _descController,
        maxLines: 4,
        onChanged: (_) => _clearError(),
        decoration: InputDecoration(
          hintText: 'Describe the issue in detail...',
          hintStyle:
              const TextStyle(fontSize: 14, color: AppColors.textGrey),
          filled: true,
          fillColor: AppColors.white,
          contentPadding: const EdgeInsets.all(16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide:
                const BorderSide(color: Colors.black26, width: 1.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide:
                const BorderSide(color: Colors.black26, width: 1.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide:
                const BorderSide(color: AppColors.green, width: 2),
          ),
        ),
      );

  Widget _noteField() => TextField(
        controller: _noteController,
        maxLines: 3,
        decoration: InputDecoration(
          hintText:
              'Extra context for staff (location details, severity...)',
          hintStyle:
              const TextStyle(fontSize: 13, color: AppColors.textGrey),
          filled: true,
          fillColor: const Color(0xFFFBF8EC),
          contentPadding: const EdgeInsets.all(16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide:
                const BorderSide(color: Color(0xFFD4C890), width: 1.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide:
                const BorderSide(color: Color(0xFFD4C890), width: 1.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide:
                const BorderSide(color: Color(0xFF9E8C2C), width: 2),
          ),
        ),
      );

  Widget _cameraButton() => SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: _takePhoto,
          icon: const Icon(Icons.camera_alt_outlined, size: 18),
          label: const Text(
            'Take Photo',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 14),
            foregroundColor: AppColors.greenDark,
            side: const BorderSide(color: Color(0xFFC8E6B0), width: 2),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            backgroundColor: const Color(0xFFF8FDF5),
          ),
        ),
      );

  Widget _photoLimitBanner() => Container(
        width: double.infinity,
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.grey.shade100,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline,
                size: 18, color: Colors.grey.shade600),
            const SizedBox(width: 10),
            Text(
              'Maximum 5 photos reached',
              style: TextStyle(
                  fontSize: 13, color: Colors.grey.shade600),
            ),
          ],
        ),
      );

  // Bytes are read once in _takePhoto — Image.memory works on web + mobile.
  Widget _thumbnailStrip() => SizedBox(
        height: 80,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _selectedImages.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) => Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.memory(
                  _selectedBytes[i],
                  width: 80,
                  height: 80,
                  fit: BoxFit.cover,
                ),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: GestureDetector(
                  onTap: () => setState(() {
                    _selectedImages.removeAt(i);
                    _selectedBytes.removeAt(i);
                  }),
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close,
                        size: 14, color: Colors.white),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
