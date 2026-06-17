// lib/screens/camera_screen.dart
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../main.dart';
import '../models/report_model.dart';
import '../services/supabase_service.dart';
import '../services/location_service.dart';
import '../services/offline_service.dart';
import '../services/detection_service.dart';
import '../utils/image_utils.dart';
import 'login_screen.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  final FlutterTts _flutterTts = FlutterTts();
  
  final _supabaseService = SupabaseService();
  final _locationService = LocationService();
  final _offlineService = OfflineService();
  final _detectionService = DetectionService();

  bool _isScannerOn = false;
  bool _isVoiceEnabled = true;
  bool _isDetecting = true;
  bool _isProcessing = false;
  String _statusText = 'Initializing...';
  int _lastProcessedTime = 0;
  List<BoundingBox> _currentBoxes = [];
  bool _modelReady = false;
  int _frameCount = 0;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  @override
  void initState() {
    super.initState();
    _initServices();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((result) {
      if (!result.contains(ConnectivityResult.none)) {
        _checkOfflineQueue();
      }
    });
  }

  Future<void> _initServices() async {
    await _detectionService.initModel();
    _modelReady = _detectionService.isReady;
    if (!_modelReady) {
      print('❌ Model failed to load!');
      if (mounted) setState(() => _statusText = 'Model load failed!');
      return;
    }
    print('✅ Model ready');
    _initTts();
    await _initCamera();
    _checkOfflineQueue();
    if (mounted) setState(() => _statusText = 'Detecting...');
  }

  Future<void> _initCamera() async {
    if (cameras.isEmpty) {
      print('❌ No cameras available');
      return;
    }
    _controller = CameraController(cameras[0], ResolutionPreset.medium, enableAudio: false);
    await _controller?.initialize();
    if (!mounted) return;
    
    setState(() {});
    
    _controller?.startImageStream((CameraImage image) {
      if (!_isScannerOn || !_isDetecting || _isProcessing || !_modelReady) return;
      
      final currentTime = DateTime.now().millisecondsSinceEpoch;
      if (currentTime - _lastProcessedTime < 150) return; // 150ms between frames for much faster updates
      
      _lastProcessedTime = currentTime;
      _processFrame(image);
    });
  }

  void _initTts() {
    _flutterTts.setLanguage("en-US");
    _flutterTts.setSpeechRate(0.5);
  }

  Future<void> _checkOfflineQueue() async {
    final connectivityResult = await Connectivity().checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none)) return;

    final queue = await _offlineService.getQueue();
    if (queue.isNotEmpty) {
      if (!mounted) return;
      setState(() {
        _isDetecting = false;
        _statusText = 'Syncing ${queue.length} offline reports...';
      });

      for (final reportData in queue.toList()) {
        try {
          final localImagePath = reportData['local_image_path'];
          final file = File(localImagePath);
          
          if (file.existsSync()) {
            final publicUrl = await _supabaseService.uploadImage(file);
            if (publicUrl != null) {
              reportData['image_url'] = publicUrl;
              reportData.remove('local_image_path');
              
              final reportModel = ReportModel.fromJson(reportData);
              final success = await _supabaseService.insertReport(reportModel);
              
              if (success) {
                await _offlineService.removeFromQueue(reportData);
                file.deleteSync();
                print('✅ Synced offline report');
              }
            }
          } else {
            await _offlineService.removeFromQueue(reportData);
          }
        } catch (e) {
          print('❌ Sync error: $e');
        }
      }

      if (mounted) {
        setState(() {
          _isDetecting = true;
          _statusText = 'Detecting...';
        });
      }
    }
  }

  Future<void> _processFrame(CameraImage image) async {
    if (_isProcessing) return;
    
    _isProcessing = true;

    try {
      final result = await _detectionService.runModelOnFrame(image);
      _frameCount++;
      
      if (result is String) {
        print("❌ ISOLATE ERROR: $result");
        if (mounted) {
          setState(() {
            _statusText = result.length > 40 ? "Err: ${result.substring(0, 40)}..." : "Err: $result";
          });
        }
        return;
      }
      
      final boxes = result as List<BoundingBox>;
      
      if (mounted) {
        setState(() {
          _currentBoxes = boxes;
          if (boxes.isNotEmpty) {
            final best = boxes.reduce((a, b) => a.confidence > b.confidence ? a : b);
            _statusText = 'Detected! ${(best.confidence * 100).toStringAsFixed(0)}%';
          } else {
            _statusText = 'Scanning...';
          }
        });
      }

      if (boxes.isNotEmpty) {
        final bestBox = boxes.reduce((curr, next) => curr.confidence > next.confidence ? curr : next);
        
        if (bestBox.confidence >= 0.50) {
          await _handleDetection(bestBox.confidence);
        }
      }
    } catch (e, st) {
      print("❌ Detection Error in _processFrame: $e\n$st");
      if (mounted) {
        setState(() => _statusText = 'Err: $e');
      }
    } finally {
      _isProcessing = false;
    }
  }

  Future<void> _handleDetection(double confidence) async {
    if (!_isDetecting) return;
    
    setState(() {
      _isDetecting = false;
      _statusText = 'Pothole detected! Processing...';
    });

    if (_isVoiceEnabled) {
      _flutterTts.speak("Pothole detected");
    }

    try {
      // 1. Stop image stream before taking picture (prevents device conflicts)
      print('📸 Stopping image stream for capture...');
      await _controller?.stopImageStream();
      
      // Small delay to let the camera settle
      await Future.delayed(const Duration(milliseconds: 300));
      
      final XFile? image = await _controller?.takePicture();
      if (image == null) {
        print('❌ Failed to take picture');
        throw Exception('Failed to take picture');
      }
      print('📸 Image captured: ${image.path}');
      
      // Compress image
      File compressedFile = await ImageUtils.compressImage(File(image.path));
      print('📸 Compressed: ${compressedFile.lengthSync()} bytes');

      // 2. Get Location
      final position = await _locationService.getCurrentLocation();
      final lat = position?.latitude ?? 0.0;
      final lng = position?.longitude ?? 0.0;

      if (lat == 0.0 && lng == 0.0) {
        print('❌ GPS Failed. Aborting upload.');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚠️ No GPS Signal! Please enable Location Services for accurate coordinates.'),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 4),
            ),
          );
        }
        if (compressedFile.existsSync()) compressedFile.deleteSync();
        _restartDetection();
        return;
      }

      final mapsLink = _locationService.getGoogleMapsLink(lat, lng);
      print('📍 Location: $lat, $lng');

      final createdAt = DateTime.now().toUtc().toIso8601String();
      print('📋 Time: $createdAt');

      // 4. Upload or save offline
      final connectivityResult = await Connectivity().checkConnectivity();
      final hasInternet = !connectivityResult.contains(ConnectivityResult.none);

      if (hasInternet) {
        if (mounted) setState(() => _statusText = 'Uploading to Supabase...');
        
        print('📤 Starting Supabase upload...');
        final publicUrl = await _supabaseService.uploadImage(compressedFile);
        
        if (publicUrl != null) {
          print('📤 Image uploaded, URL: $publicUrl');
          
          final report = ReportModel(
            createdAt: createdAt,
            latitude: lat,
            longitude: lng,
            confidence: confidence,
            mapsLink: mapsLink,
            imageUrl: publicUrl,
          );
          
          final inserted = await _supabaseService.insertReport(report);
          if (inserted) {
            print('✅ FULL UPLOAD FLOW COMPLETE — image + report sent to Supabase');
          } else {
            print('❌ Report insert failed after image upload');
          }
          if (compressedFile.existsSync()) compressedFile.deleteSync();
        } else {
          print('❌ Image upload returned null URL — saving offline instead');
          await _saveOffline(compressedFile, createdAt, lat, lng, confidence, mapsLink);
        }
      } else {
        print('📴 No internet — saving offline');
        if (mounted) setState(() => _statusText = 'Offline. Saving locally...');
        await _saveOffline(compressedFile, createdAt, lat, lng, confidence, mapsLink);
      }
    } catch (e, st) {
      print('❌ Detection Handle Error: $e\n$st');
    }

    _restartDetection();
  }

  Future<void> _saveOffline(File compressedFile, String createdAt, double lat, double lng, 
      double confidence, String mapsLink) async {
    final offlineData = {
      'created_at': createdAt,
      'latitude': lat,
      'longitude': lng,
      'confidence': confidence,
      'maps_link': mapsLink,
      'image_url': '', 
      'status': 'pending',
      'local_image_path': compressedFile.absolute.path,
    };
    await _offlineService.saveReportToQueue(offlineData);
    print('💾 Saved to offline queue');
  }

  void _restartDetection() {
    if (!mounted) return;
    
    // Restart image stream
    _controller?.startImageStream((CameraImage image) {
      if (!_isScannerOn || !_isDetecting || _isProcessing || !_modelReady) return;
      
      final currentTime = DateTime.now().millisecondsSinceEpoch;
      if (currentTime - _lastProcessedTime < 150) return;
      
      _lastProcessedTime = currentTime;
      _processFrame(image);
    });
    
    setState(() {
      _isDetecting = true;
      _statusText = 'Detecting...';
      _currentBoxes = []; // Clear boxes after upload/save done
    });
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    _controller?.dispose();
    _flutterTts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Road Security'),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await _supabaseService.signOut();
              if (context.mounted) {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (c) => const LoginScreen())
                );
              }
            },
          )
        ],
      ),
      body: Stack(
        children: [
          // Camera Preview
          Positioned.fill(
            child: CameraPreview(_controller!),
          ),
          
          // Bounding Box Overlay — always present, painter handles empty list
          Positioned.fill(
            child: CustomPaint(
              painter: BoundingBoxPainter(_currentBoxes),
            ),
          ),
          
          // Status bar overlay (Top)
          Positioned(
            top: 16, left: 24, right: 24,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.75),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white24),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (!_isDetecting || !_isScannerOn) 
                      const SizedBox(
                        width: 16, height: 16, 
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)
                      ),
                    if (!_isDetecting || !_isScannerOn) const SizedBox(width: 12),
                    // Model status indicator
                    Container(
                      width: 10, height: 10,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _modelReady ? Colors.greenAccent : Colors.redAccent,
                      ),
                    ),
                    Flexible(
                      child: Text(
                        !_isScannerOn ? "Scanner Paused" : _statusText,
                        style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.5),
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Detection count indicator
          if (_currentBoxes.isNotEmpty)
            Positioned(
              top: 80, right: 24,
              child: SafeArea(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.red.withOpacity(0.85),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_currentBoxes.length} pothole${_currentBoxes.length > 1 ? 's' : ''}',
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          
          // Floating Control Actions (Bottom)
          Positioned(
            bottom: 30, left: 10, right: 10,
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              runSpacing: 12,
              children: [
                FloatingActionButton.extended(
                  heroTag: 'scanToggle',
                  onPressed: () => setState(() {
                    _isScannerOn = !_isScannerOn;
                    if (!_isScannerOn) _currentBoxes = [];
                  }),
                  icon: Icon(_isScannerOn ? Icons.pause : Icons.play_arrow, color: Colors.white),
                  label: Text(_isScannerOn ? 'Stop Scan' : 'Start Scan', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  backgroundColor: _isScannerOn ? Colors.redAccent : Colors.teal,
                  elevation: 2,
                ),
                FloatingActionButton.extended(
                  heroTag: 'voiceToggle',
                  onPressed: () => setState(() {
                    _isVoiceEnabled = !_isVoiceEnabled;
                  }),
                  icon: Icon(_isVoiceEnabled ? Icons.volume_up : Icons.volume_off, color: Colors.white),
                  label: Text(_isVoiceEnabled ? 'Voice On' : 'Voice Muted', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  backgroundColor: Colors.deepPurple,
                  elevation: 2,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class BoundingBoxPainter extends CustomPainter {
  final List<BoundingBox> boxes;

  BoundingBoxPainter(this.boxes);

  @override
  void paint(Canvas canvas, Size size) {
    if (boxes.isEmpty) return;
    
    final boxPaint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    final bgPaint = Paint()
      ..color = Colors.red.withOpacity(0.15)
      ..style = PaintingStyle.fill;

    for (final box in boxes) {
      final rect = Rect.fromLTRB(
        box.left * size.width,
        box.top * size.height,
        box.right * size.width,
        box.bottom * size.height,
      );
      
      // Draw filled background
      canvas.drawRect(rect, bgPaint);
      // Draw border
      canvas.drawRect(rect, boxPaint);
      
      // Draw label
      final label = 'Pothole ${(box.confidence * 100).toStringAsFixed(0)}%';
      final textSpan = TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      
      // Label background
      final labelRect = Rect.fromLTWH(
        rect.left,
        rect.top > 24 ? rect.top - 24 : rect.top,
        textPainter.width + 8,
        22,
      );
      canvas.drawRect(labelRect, Paint()..color = Colors.red);
      textPainter.paint(canvas, Offset(labelRect.left + 4, labelRect.top + 2));
    }
  }

  @override
  bool shouldRepaint(covariant BoundingBoxPainter oldDelegate) {
    return oldDelegate.boxes != boxes;
  }
}
