import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

class AssetModel {
  /// Copies an asset (in Flutter assets) to a real file and returns the file path.
  static Future<String> toFilePath(String assetPath) async {
    // Put it somewhere stable on both Android/iOS
    final dir = await getApplicationSupportDirectory();

    // Preserve subfolders so you can reuse names safely
    final outFile = File('${dir.path}/$assetPath');
    await outFile.parent.create(recursive: true);

    // If already copied, reuse (fast startup)
    if (await outFile.exists() && (await outFile.length()) > 0) {
      return outFile.path;
    }

    final data = await rootBundle.load(assetPath);
    final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    await outFile.writeAsBytes(bytes, flush: true);

    return outFile.path;
  }
}
