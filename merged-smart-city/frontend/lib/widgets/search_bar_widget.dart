import 'package:flutter/material.dart';
import '../core/app_colors.dart';

class SearchBarWidget extends StatelessWidget {
  final VoidCallback onLogout;

  const SearchBarWidget({
    super.key,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 12,
      left: 10,
      right: 10,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: const [
            BoxShadow(
              blurRadius: 10,
              color: Color.fromRGBO(0, 0, 0, 0.14),
            ),
          ],
        ),
        child: Row(
          children: [
            const Icon(Icons.search, size: 18, color: AppColors.textGrey),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Search in Jordan...',
                style: TextStyle(fontSize: 13, color: AppColors.textGrey),
              ),
            ),
            InkWell(
              onTap: onLogout,
              child: Container(
                width: 30,
                height: 30,
                decoration: const BoxDecoration(
                  color: AppColors.green,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.logout_rounded, color: Colors.white, size: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }
}