import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart';

class CloudinaryService {
  // CONFIGURATION: Customize these for your own Cloudinary Account!
  static const String cloudName = 'dtpydep9j';
  static const String uploadPreset = 'postmark_preset';
  static const String apiKey = '676239922233615';
  static const String apiSecret = 'lVq9rZ6vU-ZzK0Q7uWlh1r8W_C8';

  /// Uploads any file to Cloudinary.
  /// [resourceType] can be 'image', 'video', or 'raw' (for general files).
  static Future<Map<String, String>?> uploadFile({
    required File file,
    required String resourceType,
  }) async {
    try {
      final url = Uri.parse('https://api.cloudinary.com/v1_1/$cloudName/$resourceType/upload');
      
      final request = http.MultipartRequest('POST', url)
        ..fields['upload_preset'] = uploadPreset
        ..files.add(await http.MultipartFile.fromPath('file', file.path));

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200 || response.statusCode == 201) {
        final data = json.decode(response.body);
        return {
          'url': data['secure_url'] as String,
          'public_id': data['public_id'] as String,
        };
      } else {
        debugPrint('Cloudinary Upload Failed: ${response.body}');
        return null;
      }
    } catch (e) {
      debugPrint('Cloudinary Upload Error: $e');
      return null;
    }
  }

  /// Deletes a file from Cloudinary securely using a client-side signature.
  static Future<bool> destroyFile({
    required String publicId,
    required String resourceType,
  }) async {
    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      
      // Signature formula: sha256("public_id=<public_id>&timestamp=<timestamp><apiSecret>")
      final signatureInput = 'public_id=$publicId&timestamp=$timestamp$apiSecret';
      final signature = sha256.convert(utf8.encode(signatureInput)).toString();

      final url = Uri.parse('https://api.cloudinary.com/v1_1/$cloudName/$resourceType/destroy');
      final response = await http.post(url, body: {
        'public_id': publicId,
        'timestamp': timestamp.toString(),
        'api_key': apiKey,
        'signature': signature,
      });

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['result'] == 'ok';
      } else {
        debugPrint('Cloudinary Destroy Failed: ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('Cloudinary Destroy Error: $e');
      return false;
    }
  }

  /// Downloads media from a url and saves it locally in internal storage under a folder called "PostMark Media".
  static Future<String?> saveFileToLocalFolder(String fileUrl, String originalFileName) async {
    try {
      // 1. Request Storage Permissions
      if (Platform.isAndroid || Platform.isIOS) {
        var status = await Permission.storage.status;
        if (!status.isGranted) {
          status = await Permission.storage.request();
          if (!status.isGranted) {
            // Try manageExternalStorage if on newer Android versions
            if (Platform.isAndroid) {
              var manageStatus = await Permission.manageExternalStorage.request();
              if (!manageStatus.isGranted) {
                debugPrint('Storage Permissions Denied!');
                return null;
              }
            } else {
              return null;
            }
          }
        }
      }

      // 2. Find/Create "PostMark Media" folder path
      Directory? targetDirectory;
      if (Platform.isWindows) {
        final docsDir = await getApplicationDocumentsDirectory();
        targetDirectory = Directory('${docsDir.path}/PostMark Media');
      } else if (Platform.isAndroid) {
        // Try external download folder or standard docs
        targetDirectory = Directory('/storage/emulated/0/Download/PostMark Media');
        if (!await targetDirectory.exists()) {
          targetDirectory = Directory('/storage/emulated/0/Documents/PostMark Media');
        }
        if (!await targetDirectory.exists()) {
          final externalDir = await getExternalStorageDirectory();
          if (externalDir != null) {
            targetDirectory = Directory('${externalDir.path}/PostMark Media');
          }
        }
      } else {
        final appDocDir = await getApplicationDocumentsDirectory();
        targetDirectory = Directory('${appDocDir.path}/PostMark Media');
      }

      if (!await targetDirectory.exists()) {
        await targetDirectory.create(recursive: true);
      }

      final localFilePath = '${targetDirectory.path}/$originalFileName';
      final localFile = File(localFilePath);

      // 3. Download the file bytes
      final response = await http.get(Uri.parse(fileUrl));
      if (response.statusCode == 200) {
        await localFile.writeAsBytes(response.bodyBytes);
        return localFilePath;
      } else {
        debugPrint('Download Failed: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      debugPrint('Download/Local Save Error: $e');
      return null;
    }
  }
}
