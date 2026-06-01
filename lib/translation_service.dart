import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class TranslationService {
  static final Map<String, String> languages = {
    'English': 'en',
    'Spanish': 'es',
    'French': 'fr',
    'German': 'de',
    'Hindi': 'hi',
    'Arabic': 'ar',
    'Japanese': 'ja',
    'Chinese': 'zh',
    'Portuguese': 'pt',
    'Italian': 'it',
    'Russian': 'ru',
    'Telugu': 'te',
    'Tamil': 'ta',
    'Bengali': 'bn',
  };

  static String getLanguageCode(String lang) {
    return languages[lang] ?? 'en';
  }

  static Future<String> translate(String text, String targetLang) async {
    if (text.trim().isEmpty) return '';
    try {
      final code = getLanguageCode(targetLang);
      final url = 'https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=$code&dt=t&q=${Uri.encodeComponent(text)}';
      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is List && decoded.isNotEmpty && decoded[0] is List) {
          final parts = decoded[0] as List;
          final translated = parts.map((part) {
            if (part is List && part.isNotEmpty) {
              return part[0].toString();
            }
            return '';
          }).join('');
          return translated;
        }
      }
    } catch (e) {
      debugPrint('Translation error: $e');
    }
    return text; // Fallback to original text if translation fails
  }
}
