// lib/services/detection_service.dart
import 'dart:math';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:tflite_flutter/tflite_flutter.dart';

class BoundingBox {
  final double left;
  final double top;
  final double right;
  final double bottom;
  final double confidence;

  BoundingBox(this.left, this.top, this.right, this.bottom, this.confidence);
}

class IsolateInitData {
  final SendPort sendPort;
  final Uint8List modelBytes;
  IsolateInitData(this.sendPort, this.modelBytes);
}

class FrameData {
  final SendPort replyPort;
  final int width;
  final int height;
  final Uint8List yPlane;
  final Uint8List uPlane;
  final Uint8List vPlane;
  final int yRowStride;
  final int uvRowStride;
  final int uvPixelStride;

  FrameData(this.replyPort, this.width, this.height, this.yPlane, this.uPlane,
      this.vPlane, this.yRowStride, this.uvRowStride, this.uvPixelStride);
}

class DetectionService {
  Isolate? _isolate;
  SendPort? _sendPort;
  bool _isReady = false;

  bool get isReady => _isReady;

  Future<void> initModel() async {
    try {
      print('⏳ Loading best.tflite from assets...');
      final modelData = await rootBundle.load('assets/best.tflite');
      final modelBytes = modelData.buffer.asUint8List();

      final receivePort = ReceivePort();
      _isolate = await Isolate.spawn(
        _isolateMain,
        IsolateInitData(receivePort.sendPort, modelBytes),
        debugName: 'YOLOv8_Isolate',
      );

      _sendPort = await receivePort.first as SendPort;
      _isReady = true;
      print('✅ Isolate and Model loaded successfully!');
    } catch (e) {
      print('❌ MODEL LOAD FAILED: $e');
    }
  }

  /// Returns List<BoundingBox> on success, or String on error.
  Future<dynamic> runModelOnFrame(CameraImage image) async {
    if (!_isReady || _sendPort == null) return <BoundingBox>[];

    final yPlane = Uint8List.fromList(image.planes[0].bytes);
    final uPlane = Uint8List.fromList(image.planes[1].bytes);
    final vPlane = Uint8List.fromList(image.planes[2].bytes);

    final replyPort = ReceivePort();
    _sendPort!.send(FrameData(
      replyPort.sendPort,
      image.width, image.height,
      yPlane, uPlane, vPlane,
      image.planes[0].bytesPerRow,
      image.planes[1].bytesPerRow,
      image.planes[1].bytesPerPixel ?? 1,
    ));

    final result = await replyPort.first;

    // Isolate sends List<List<double>> (primitives only) to avoid serialization issues
    if (result is List) {
      return result.map((b) {
        final box = b as List;
        return BoundingBox(
          (box[0] as num).toDouble(),
          (box[1] as num).toDouble(),
          (box[2] as num).toDouble(),
          (box[3] as num).toDouble(),
          (box[4] as num).toDouble(),
        );
      }).toList();
    }

    // Error string from isolate
    return result;
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isReady = false;
  }

  // ==========================================
  // ISOLATE BACKGROUND CODE
  // ==========================================
  static void _isolateMain(IsolateInitData initData) async {
    final isolateReceivePort = ReceivePort();
    initData.sendPort.send(isolateReceivePort.sendPort);

    Interpreter? interpreter;
    bool isInputFloat = true;
    bool isNCHW = false;
    bool outTransposed = false;
    int numClasses = 1;
    int anchorCount = 8400;
    int inputSize = 640;
    bool isOutputFloat = true;

    late List<dynamic> inputBuffer;
    late List<dynamic> outputBuffer;

    int frameCount = 0;

    try {
      interpreter = Interpreter.fromBuffer(
        initData.modelBytes,
        options: InterpreterOptions()..threads = 4,
      );

      final inputTensor = interpreter.getInputTensor(0);
      final outputTensor = interpreter.getOutputTensor(0);
      final inShape = inputTensor.shape;
      final outShape = outputTensor.shape;
      final inputType = inputTensor.type.toString();
      final outputType = outputTensor.type.toString();

      isInputFloat = inputType.contains('float');
      isOutputFloat = outputType.contains('float');

      // Detect layout and size
      if (inShape.length == 4) {
        if (inShape[1] == 3) {
          isNCHW = true;
          inputSize = inShape[2];
        } else {
          isNCHW = false;
          inputSize = inShape[1];
        }
      }

      print('🔍 INPUT:  shape=$inShape type=$inputType NCHW=$isNCHW size=$inputSize');
      print('🔍 OUTPUT: shape=$outShape type=$outputType');

      // Parse output shape
      if (outShape.length == 3) {
        if (outShape[1] < outShape[2]) {
          outTransposed = false;
          numClasses = outShape[1] - 4;
          anchorCount = outShape[2];
        } else {
          outTransposed = true;
          numClasses = outShape[2] - 4;
          anchorCount = outShape[1];
        }
      }
      if (numClasses < 1) numClasses = 1;

      print('🔍 PARSED: classes=$numClasses anchors=$anchorCount transposed=$outTransposed outFloat=$isOutputFloat');

      // Allocate input buffer
      if (isInputFloat) {
        if (isNCHW) {
          inputBuffer = List<List<List<List<double>>>>.generate(1, (_) => List<List<List<double>>>.generate(3, (_) =>
            List<List<double>>.generate(inputSize, (_) => List<double>.filled(inputSize, 0.0))));
        } else {
          inputBuffer = List<List<List<List<double>>>>.generate(1, (_) => List<List<List<double>>>.generate(inputSize, (_) =>
            List<List<double>>.generate(inputSize, (_) => List<double>.filled(3, 0.0))));
        }
      } else {
        if (isNCHW) {
          inputBuffer = List<List<List<List<int>>>>.generate(1, (_) => List<List<List<int>>>.generate(3, (_) =>
            List<List<int>>.generate(inputSize, (_) => List<int>.filled(inputSize, 0))));
        } else {
          inputBuffer = List<List<List<List<int>>>>.generate(1, (_) => List<List<List<int>>>.generate(inputSize, (_) =>
            List<List<int>>.generate(inputSize, (_) => List<int>.filled(3, 0))));
        }
      }

      // Allocate output buffer matching model output type
      int dim1 = outShape[1];
      int dim2 = outShape[2];
      if (isOutputFloat) {
        outputBuffer = List<List<List<double>>>.generate(1, (_) =>
          List<List<double>>.generate(dim1, (_) => List<double>.filled(dim2, 0.0)));
      } else {
        outputBuffer = List<List<List<int>>>.generate(1, (_) =>
          List<List<int>>.generate(dim1, (_) => List<int>.filled(dim2, 0)));
      }

      print('✅ ISOLATE READY: buffers allocated');

    } catch (e, st) {
      print("❌ ISOLATE MODEL INIT ERROR: $e\n$st");
      return;
    }

    // ── Frame processing loop ──
    await for (final message in isolateReceivePort) {
      if (message is FrameData) {
        try {
          frameCount++;
          final int T = inputSize;
          final bool rotate = message.width > message.height;
          final int logW = rotate ? message.height : message.width;
          final int logH = rotate ? message.width : message.height;
          final double scX = logW / T;
          final double scY = logH / T;

          // ── PRECOMPUTE LOOKUPS FOR EXTREME SPEED ──
          List<int> txToSx = List<int>.filled(T, 0);
          List<int> tyToSy = List<int>.filled(T, 0);
          List<int> tyToSxRot = List<int>.filled(T, 0);
          List<int> txToSyRot = List<int>.filled(T, 0);

          if (rotate) {
            for (int i = 0; i < T; i++) {
              tyToSxRot[i] = (i * scY).toInt().clamp(0, message.width - 1);
              txToSyRot[i] = ((T - 1 - i) * scX).toInt().clamp(0, message.height - 1);
            }
          } else {
            for (int i = 0; i < T; i++) {
              txToSx[i] = (i * scX).toInt().clamp(0, message.width - 1);
              tyToSy[i] = (i * scY).toInt().clamp(0, message.height - 1);
            }
          }

          // YUV→RGB + fill input
          if (isInputFloat) {
            if (isNCHW) {
              var buf = inputBuffer as List<List<List<List<double>>>>;
              for (int ty = 0; ty < T; ty++) {
                int sxRot = rotate ? tyToSxRot[ty] : 0;
                int syNoRot = rotate ? 0 : tyToSy[ty];
                for (int tx = 0; tx < T; tx++) {
                  int sx = rotate ? sxRot : txToSx[tx];
                  int sy = rotate ? txToSyRot[tx] : syNoRot;
                  final int yIdx = sy * message.yRowStride + sx;
                  final int uvIdx = (sy >> 1) * message.uvRowStride + (sx >> 1) * message.uvPixelStride;
                  if (yIdx >= message.yPlane.length || uvIdx >= message.uPlane.length || uvIdx >= message.vPlane.length) continue;
                  int r = (1192 * message.yPlane[yIdx] + 1634 * (message.vPlane[uvIdx] - 128)) >> 10;
                  int g = (1192 * message.yPlane[yIdx] - 400 * (message.uPlane[uvIdx] - 128) - 833 * (message.vPlane[uvIdx] - 128)) >> 10;
                  int b = (1192 * message.yPlane[yIdx] + 2066 * (message.uPlane[uvIdx] - 128)) >> 10;
                  buf[0][0][ty][tx] = r.clamp(0, 255) / 255.0;
                  buf[0][1][ty][tx] = g.clamp(0, 255) / 255.0;
                  buf[0][2][ty][tx] = b.clamp(0, 255) / 255.0;
                }
              }
            } else {
              var buf = inputBuffer as List<List<List<List<double>>>>;
              for (int ty = 0; ty < T; ty++) {
                int sxRot = rotate ? tyToSxRot[ty] : 0;
                int syNoRot = rotate ? 0 : tyToSy[ty];
                for (int tx = 0; tx < T; tx++) {
                  int sx = rotate ? sxRot : txToSx[tx];
                  int sy = rotate ? txToSyRot[tx] : syNoRot;
                  final int yIdx = sy * message.yRowStride + sx;
                  final int uvIdx = (sy >> 1) * message.uvRowStride + (sx >> 1) * message.uvPixelStride;
                  if (yIdx >= message.yPlane.length || uvIdx >= message.uPlane.length) continue;
                  int r = (1192 * message.yPlane[yIdx] + 1634 * (message.vPlane[uvIdx] - 128)) >> 10;
                  int g = (1192 * message.yPlane[yIdx] - 400 * (message.uPlane[uvIdx] - 128) - 833 * (message.vPlane[uvIdx] - 128)) >> 10;
                  int b = (1192 * message.yPlane[yIdx] + 2066 * (message.uPlane[uvIdx] - 128)) >> 10;
                  buf[0][ty][tx][0] = r.clamp(0, 255) / 255.0;
                  buf[0][ty][tx][1] = g.clamp(0, 255) / 255.0;
                  buf[0][ty][tx][2] = b.clamp(0, 255) / 255.0;
                }
              }
            }
          } else {
            if (isNCHW) {
              var buf = inputBuffer as List<List<List<List<int>>>>;
              for (int ty = 0; ty < T; ty++) {
                int sxRot = rotate ? tyToSxRot[ty] : 0;
                int syNoRot = rotate ? 0 : tyToSy[ty];
                for (int tx = 0; tx < T; tx++) {
                  int sx = rotate ? sxRot : txToSx[tx];
                  int sy = rotate ? txToSyRot[tx] : syNoRot;
                  final int yIdx = sy * message.yRowStride + sx;
                  final int uvIdx = (sy >> 1) * message.uvRowStride + (sx >> 1) * message.uvPixelStride;
                  if (yIdx >= message.yPlane.length || uvIdx >= message.uPlane.length) continue;
                  int r = (1192 * message.yPlane[yIdx] + 1634 * (message.vPlane[uvIdx] - 128)) >> 10;
                  int g = (1192 * message.yPlane[yIdx] - 400 * (message.uPlane[uvIdx] - 128) - 833 * (message.vPlane[uvIdx] - 128)) >> 10;
                  int b = (1192 * message.yPlane[yIdx] + 2066 * (message.uPlane[uvIdx] - 128)) >> 10;
                  buf[0][0][ty][tx] = r.clamp(0, 255);
                  buf[0][1][ty][tx] = g.clamp(0, 255);
                  buf[0][2][ty][tx] = b.clamp(0, 255);
                }
              }
            } else {
              var buf = inputBuffer as List<List<List<List<int>>>>;
              for (int ty = 0; ty < T; ty++) {
                int sxRot = rotate ? tyToSxRot[ty] : 0;
                int syNoRot = rotate ? 0 : tyToSy[ty];
                for (int tx = 0; tx < T; tx++) {
                  int sx = rotate ? sxRot : txToSx[tx];
                  int sy = rotate ? txToSyRot[tx] : syNoRot;
                  final int yIdx = sy * message.yRowStride + sx;
                  final int uvIdx = (sy >> 1) * message.uvRowStride + (sx >> 1) * message.uvPixelStride;
                  if (yIdx >= message.yPlane.length || uvIdx >= message.uPlane.length) continue;
                  int r = (1192 * message.yPlane[yIdx] + 1634 * (message.vPlane[uvIdx] - 128)) >> 10;
                  int g = (1192 * message.yPlane[yIdx] - 400 * (message.uPlane[uvIdx] - 128) - 833 * (message.vPlane[uvIdx] - 128)) >> 10;
                  int b = (1192 * message.yPlane[yIdx] + 2066 * (message.uPlane[uvIdx] - 128)) >> 10;
                  buf[0][ty][tx][0] = r.clamp(0, 255);
                  buf[0][ty][tx][1] = g.clamp(0, 255);
                  buf[0][ty][tx][2] = b.clamp(0, 255);
                }
              }
            }
          }

          // Run inference
          interpreter!.run(inputBuffer, outputBuffer);

          // ── Diagnostic logging on first 3 frames ──
          if (frameCount <= 3) {
            double rawMax = -999999;
            double rawMin = 999999;
            for (int i = 0; i < min(200, anchorCount); i++) {
              for (int c = 0; c < numClasses; c++) {
                double v;
                if (outTransposed) {
                  v = (outputBuffer[0][i][4 + c] as num).toDouble();
                } else {
                  v = (outputBuffer[0][4 + c][i] as num).toDouble();
                }
                if (v > rawMax) rawMax = v;
                if (v < rawMin) rawMin = v;
              }
            }
            // Also log a sample box coordinate
            double sampleX, sampleY;
            if (outTransposed) {
              sampleX = (outputBuffer[0][0][0] as num).toDouble();
              sampleY = (outputBuffer[0][0][1] as num).toDouble();
            } else {
              sampleX = (outputBuffer[0][0][0] as num).toDouble();
              sampleY = (outputBuffer[0][1][0] as num).toDouble();
            }
            print('📊 FRAME#$frameCount: rawScoreRange=[$rawMin .. $rawMax] sampleXY=($sampleX, $sampleY) cam=${message.width}x${message.height} rotate=$rotate');
          }

          // ── Decode YOLOv8 output ──
          List<List<double>> boxesRaw = [];
          
          double outputScale = 1.0;
          double outputZeroPoint = 0.0;
          if (!isOutputFloat) {
             final params = interpreter!.getOutputTensor(0).params;
             outputScale = params.scale > 0 ? params.scale : 1.0;
             outputZeroPoint = params.zeroPoint.toDouble();
          }

          for (int i = 0; i < anchorCount; i++) {
            double cx, cy, w, h;
            if (outTransposed) {
              cx = (outputBuffer[0][i][0] as num).toDouble();
              cy = (outputBuffer[0][i][1] as num).toDouble();
              w  = (outputBuffer[0][i][2] as num).toDouble();
              h  = (outputBuffer[0][i][3] as num).toDouble();
            } else {
              cx = (outputBuffer[0][0][i] as num).toDouble();
              cy = (outputBuffer[0][1][i] as num).toDouble();
              w  = (outputBuffer[0][2][i] as num).toDouble();
              h  = (outputBuffer[0][3][i] as num).toDouble();
            }

            // Dequantize coordinates if needed
            if (!isOutputFloat) {
              cx = (cx - outputZeroPoint) * outputScale;
              cy = (cy - outputZeroPoint) * outputScale;
              w  = (w  - outputZeroPoint) * outputScale;
              h  = (h  - outputZeroPoint) * outputScale;
            }

            // Find best class score
            double bestScore = -999999;
            for (int c = 0; c < numClasses; c++) {
              double val;
              if (outTransposed) {
                val = (outputBuffer[0][i][4 + c] as num).toDouble();
              } else {
                val = (outputBuffer[0][4 + c][i] as num).toDouble();
              }
              if (!isOutputFloat) {
                 val = (val - outputZeroPoint) * outputScale;
              }
              if (val > bestScore) bestScore = val;
            }

            // If YOLOv5 model format (obj * class), we attempt a heuristic: if numClasses == 2 and one is objectness
            // BUT usually YOLOv8 has numClasses=1 for one class. So this logic assumes direct class score.

            double confidence = bestScore;

            if (confidence >= 0.45) {
              // Auto-detect pixel-space vs normalized coords
              double norm = (cx > 2.0 || cy > 2.0 || w > 2.0 || h > 2.0) ? T.toDouble() : 1.0;
              double left   = ((cx - w / 2) / norm).clamp(0.0, 1.0);
              double top    = ((cy - h / 2) / norm).clamp(0.0, 1.0);
              double right  = ((cx + w / 2) / norm).clamp(0.0, 1.0);
              double bottom = ((cy + h / 2) / norm).clamp(0.0, 1.0);

              boxesRaw.add([left, top, right, bottom, confidence]);
            }
          }

          // NMS
          boxesRaw = _nmsRaw(boxesRaw, 0.45);

          if (frameCount <= 3) {
            print('📦 FRAME#$frameCount: ${boxesRaw.length} detections after NMS');
          }

          // Send ONLY primitive List<List<double>> — avoids isolate serialization issues
          message.replyPort.send(boxesRaw);

        } catch (e, st) {
          print("❌ ISOLATE FRAME ERROR: $e");
          message.replyPort.send("ISOLATE_ERR: $e | $st");
        }
      }
    }
  }

  static double _sigmoid(double x) {
    if (x >= 0) {
      return 1.0 / (1.0 + exp(-x));
    } else {
      final ex = exp(x);
      return ex / (1.0 + ex);
    }
  }

  static List<List<double>> _nmsRaw(List<List<double>> boxes, double iouThreshold) {
    if (boxes.isEmpty) return [];
    boxes.sort((a, b) => b[4].compareTo(a[4]));
    List<List<double>> results = [];
    List<bool> active = List<bool>.filled(boxes.length, true);
    for (int i = 0; i < boxes.length; i++) {
      if (!active[i]) continue;
      results.add(boxes[i]);
      for (int j = i + 1; j < boxes.length; j++) {
        if (!active[j]) continue;
        if (_iouRaw(boxes[i], boxes[j]) > iouThreshold) active[j] = false;
      }
    }
    return results;
  }

  static double _iouRaw(List<double> a, List<double> b) {
    double xA = max(a[0], b[0]), yA = max(a[1], b[1]);
    double xB = min(a[2], b[2]), yB = min(a[3], b[3]);
    double inter = max(0.0, xB - xA) * max(0.0, yB - yA);
    double aA = (a[2] - a[0]) * (a[3] - a[1]);
    double aB = (b[2] - b[0]) * (b[3] - b[1]);
    double union = aA + aB - inter;
    if (union <= 0) return 0;
    return inter / union;
  }
}
