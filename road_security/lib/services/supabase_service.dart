import 'dart:io';
import 'package:flutter/services.dart' show rootBundle;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/report_model.dart';
import 'package:path/path.dart' as p;

class SupabaseService {
  final SupabaseClient _client = Supabase.instance.client;

  // Sign in
  Future<AuthResponse> signIn(String email, String password) async {
    return await _client.auth.signInWithPassword(email: email, password: password);
  }
  
  // Sign out
  Future<void> signOut() async {
    await _client.auth.signOut();
  }

  // Upload an image to storage and return public URL
  Future<String?> uploadImage(File imageFile) async {
    try {
      final fileName = '${DateTime.now().millisecondsSinceEpoch}_${p.basename(imageFile.path)}';
      print('📤 UPLOADING image: $fileName (${imageFile.lengthSync()} bytes)');
      final path = await _client.storage.from('potholes').upload(
            fileName,
            imageFile,
            fileOptions: const FileOptions(cacheControl: '3600', upsert: false),
          );
      print('📤 Upload path returned: $path');
      
      final imageUrl = _client.storage.from('potholes').getPublicUrl(fileName);
      print('📤 Public URL: $imageUrl');
      return imageUrl;
    } catch (e) {
      print('❌ Upload Error: $e');
      return null;
    }
  }

  // Insert a report into hazards table
  Future<bool> insertReport(ReportModel report) async {
    try {
      final json = report.toJson();
      print('📝 INSERTING report: $json');
      await _client.from('hazards').insert(json);
      print('✅ Report inserted successfully!');
      return true;
    } catch (e) {
      print('❌ Insert Error: $e');
      return false;
    }
  }

  // Fetch all reports for admin
  Future<List<ReportModel>> fetchReports() async {
    try {
      final data = await _client.from('hazards').select().order('created_at', ascending: false);
      return (data as List).map((e) => ReportModel.fromJson(e)).toList();
    } catch (e) {
      print('Fetch Error: $e');
      return [];
    }
  }

  // Sign up
  Future<void> signUp(String email, String password) async {
    try {
      await _client.auth.signUp(
        email: email,
        password: password,
      );
    } catch (e) {
      throw Exception('Sign up failed: $e');
    }
  }

  // Update report to solved
  Future<bool> markAsSolved(String id) async {
    try {
      await _client.from('hazards').update({'status': 'solved'}).eq('id', id);
      return true;
    } catch (e) {
      print('Update Error: $e');
      return false;
    }
  }
}
