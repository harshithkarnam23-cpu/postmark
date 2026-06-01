import 'translation_service.dart';

class AIAssistantService {
  // Translate + Tone/Mood decoration for Auto Transform / Auto Type
  static Future<String> transformMessage({
    required String roughDraft,
    required String mood,
    required String targetLanguage,
  }) async {
    if (roughDraft.trim().isEmpty) {
      return _generateDefaultMessageForMood(mood, targetLanguage);
    }

    // 1. Translate the user's rough draft to the target language
    final translated = await TranslationService.translate(roughDraft, targetLanguage);

    // 2. Decorate the translated text with the appropriate mood structure
    return _decorateTextWithMood(translated, mood, targetLanguage);
  }

  static String _generateDefaultMessageForMood(String mood, String lang) {
    switch (mood.toLowerCase()) {
      case 'happy':
        return 'I am feeling wonderful and so happy today! 😊✨';
      case 'angry':
        return 'This is completely unacceptable and I am very upset. 😡';
      case 'sad':
        return 'I am feeling quite sad and down right now. 😢';
      case 'tension':
        return 'I am feeling really stressed and worried about this. 😰';
      case 'excited':
        return 'I am super excited and can\'t wait for this! 🤩🎉';
      case 'chill':
        return 'Everything is chill, no worries at all. 😎';
      case 'child safety':
      case 'childsafety':
      case 'child_safety':
        return 'Please ensure this conversation is safe, respectful, and appropriate for children. 🛡️';
      default:
        return 'Hello! How are you doing? 😐';
    }
  }

  static String _decorateTextWithMood(String text, String mood, String lang) {
    final cleaned = text.trim();
    switch (mood.toLowerCase()) {
      case 'happy':
        return 'Wonderful news! 😊 $cleaned ✨ Hope you\'re having a great day! 🎉';
      case 'angry':
        return 'This is highly frustrating. 😡 $cleaned. This needs attention immediately. 💢';
      case 'sad':
        return 'I\'m quite sorry to say this, 😢 but $cleaned. 💔';
      case 'tension':
        return 'I am deeply concerned about this... 😰 $cleaned. Hopefully we can resolve this soon. ⏳';
      case 'excited':
        return 'Awesome! 🤩 $cleaned!! So looking forward to this! 🔥🚀';
      case 'chill':
        return 'Hey, no sweat! 😎 $cleaned. All good! 👍';
      case 'child safety':
      case 'childsafety':
      case 'child_safety':
        return 'Safety Notice: 🛡️ $cleaned. Let\'s keep it safe. 🤝';
      default: // Professional / Neutral
        return 'Hello, I hope you are doing well. 💼 $cleaned. Thank you. 👔';
    }
  }

  // Generate Tone analysis report / Message meaning
  static Map<String, String> getMessageMeaning(String text) {
    if (text.trim().isEmpty) {
      return {
        'meaning': 'No message text provided.',
        'tone': 'Neutral 😐',
        'empathy': 'Please select a message with content.',
      };
    }

    if (text.startsWith('anim_emoji_noto:')) {
      return {
        'meaning': 'The sender shared an animated sticker expression to convey non-verbal emotion.',
        'tone': 'Playful & Expressive 🎬',
        'empathy': 'Stickers are a fun way to share immediate feelings and expressions!',
      };
    }

    final lower = text.toLowerCase();
    String tone = 'Friendly & Casual 😊';
    String meaning = 'The sender is sharing a casual update or checking in.';
    String empathy = 'Try responding with a friendly or neutral tone to match their vibe.';

    if (lower.contains('sorry') || lower.contains('apologize') || lower.contains('forgive')) {
      tone = 'Polite & Apologetic 🙇‍♂️';
      meaning = 'The sender is expressing regret or apologizing for an issue.';
      empathy = 'Acknowledge their apology with understanding and reassurance.';
    } else if (lower.contains('thank') || lower.contains('thanks') || lower.contains('grateful') || lower.contains('appreciate')) {
      tone = 'Appreciative & Warm 🙏';
      meaning = 'The sender is expressing gratitude and appreciation.';
      empathy = 'Respond with a warm "You\'re welcome!" or custom expression.';
    } else if (lower.contains('urgent') || lower.contains('asap') || lower.contains('hurry') || lower.contains('quick') || lower.contains('need')) {
      tone = 'Urgent & Action-oriented 🚨';
      meaning = 'The sender needs prompt assistance or has an immediate request.';
      empathy = 'Reply quickly or let them know when you will be able to take action.';
    } else if (lower.contains('angry') || lower.contains('hate') || lower.contains('stop') || lower.contains('why') && (lower.contains('late') || lower.contains('bad'))) {
      tone = 'Frustrated or Annoyed 😡';
      meaning = 'The sender is expressing dissatisfaction or frustration.';
      empathy = 'Remain calm, polite, and offer help to de-escalate the tension.';
    } else if (lower.contains('love') || lower.contains('dear') || lower.contains('miss') || lower.contains('sweet')) {
      tone = 'Affectionate & Caring 🥰';
      meaning = 'The sender is sending warm, affectionate thoughts.';
      empathy = 'Reply with a caring, warm message to reciprocate their closeness.';
    } else if (text.endsWith('?') || lower.contains('why') || lower.contains('how') || lower.contains('what') || lower.contains('when')) {
      tone = 'Inquisitive & Curious 🔍';
      meaning = 'The sender is asking a question or seeking details.';
      empathy = 'Provide a clear, helpful answer to their question.';
    } else if (text.contains('!') && (lower.contains('yay') || lower.contains('great') || lower.contains('happy') || lower.contains('yes'))) {
      tone = 'Excited & Enthusiastic 🤩';
      meaning = 'The sender is celebrating good news or expressing excitement.';
      empathy = 'Share in their excitement with high energy or matching emojis!';
    }

    return {
      'meaning': meaning,
      'tone': tone,
      'empathy': empathy,
    };
  }
}
