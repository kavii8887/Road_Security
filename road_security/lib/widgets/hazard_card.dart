// lib/widgets/hazard_card.dart
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/report_model.dart';
import '../services/supabase_service.dart';

class HazardCard extends StatelessWidget {
  final ReportModel report;
  final VoidCallback onStatusChanged;
  
  const HazardCard({super.key, required this.report, required this.onStatusChanged});

  void _openMap() async {
    final url = Uri.parse(report.mapsLink);
    // Directly launch in external browser/maps app, ignore canLaunch check which fails on Android 11+ without explicit queries
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      print('Could not launch map: $e');
    }
  }

  void _markSolved(BuildContext context) async {
    final sbService = SupabaseService();
    final id = report.id;
    if (id != null) {
      bool success = await sbService.markAsSolved(id);
      if (success) {
        onStatusChanged();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Marked as solved!')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Color severityColor = Colors.green;
    String severityText = 'LOW';
    if (report.confidence > 0.90) {
      severityColor = Colors.red;
      severityText = 'CRITICAL';
    } else if (report.confidence > 0.80) {
      severityColor = Colors.orange;
      severityText = 'HIGH';
    } else if (report.confidence > 0.70) {
      severityColor = Colors.amber;
      severityText = 'MEDIUM';
    }

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 4,
      shadowColor: Colors.black12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Image
          report.imageUrl.isNotEmpty
              ? Image.network(
                  report.imageUrl,
                  width: 120,
                  height: 140,
                  fit: BoxFit.cover,
                  errorBuilder: (c, e, s) => Container(
                    width: 120, height: 140, color: Colors.grey[200],
                    child: const Icon(Icons.image_not_supported, color: Colors.grey),
                  ),
                )
              : Container(
                  width: 120, height: 140, color: Colors.grey[200],
                  child: const Icon(Icons.image, color: Colors.grey),
                ),
                
          // Info
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: severityColor.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: severityColor.withOpacity(0.5))
                        ),
                        child: Text(
                          severityText,
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: severityColor),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: report.status == 'solved' ? Colors.green[50] : Colors.blue[50],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          report.status.toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: report.status == 'solved' ? Colors.green : Colors.blue
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Conf: ${(report.confidence * 100).toStringAsFixed(1)}%',
                    style: TextStyle(color: Colors.grey[800], fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '📍 ${report.latitude.toStringAsFixed(5)}, ${report.longitude.toStringAsFixed(5)}',
                    style: TextStyle(color: Colors.grey[700], fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '🕒 ${_formatDate(report.createdAt)}',
                    style: TextStyle(color: Colors.grey[700], fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.map, size: 16),
                        label: const Text('Map', style: TextStyle(fontSize: 12)),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        onPressed: _openMap,
                      ),
                      if (report.status != 'solved')
                        ElevatedButton.icon(
                          icon: const Icon(Icons.check, size: 16),
                          label: const Text('Solve', style: TextStyle(fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            elevation: 0,
                          ),
                          onPressed: () => _markSolved(context),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  String _formatDate(String isoString) {
    try {
      final dt = DateTime.parse(isoString).toLocal();
      final hours = dt.hour > 12 ? dt.hour - 12 : (dt.hour == 0 ? 12 : dt.hour);
      final amPm = dt.hour >= 12 ? 'PM' : 'AM';
      final min = dt.minute.toString().padLeft(2, '0');
      final dd = dt.day.toString().padLeft(2, '0');
      final mm = dt.month.toString().padLeft(2, '0');
      final yy = (dt.year % 100).toString().padLeft(2, '0');
      return '$dd/$mm/$yy $hours:$min $amPm';
    } catch (_) {
      return 'Unknown Date';
    }
  }
}
