// lib/services/offline_service.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class OfflineService {
  static const String queueKey = 'offline_queue';

  // Save a pending report locally. We include the local image path in the JSON.
  Future<void> saveReportToQueue(Map<String, dynamic> reportData) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> queue = prefs.getStringList(queueKey) ?? [];
    queue.add(jsonEncode(reportData));
    await prefs.setStringList(queueKey, queue);
  }

  // Get all pending reports
  Future<List<Map<String, dynamic>>> getQueue() async {
    final prefs = await SharedPreferences.getInstance();
    List<String> queue = prefs.getStringList(queueKey) ?? [];
    return queue.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
  }

  // Remove a report from the queue
  Future<void> removeFromQueue(Map<String, dynamic> reportData) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> queue = prefs.getStringList(queueKey) ?? [];
    // Convert current report to string representation that matches
    final reportString = jsonEncode(reportData);
    queue.remove(reportString);
    await prefs.setStringList(queueKey, queue);
  }
}
