import re

with open('lib/chat_page.dart', 'r', encoding='utf-8') as f:
    content = f.read()

target = r"final type = 'media_file';"

replacement = """String type = 'media_file';
      final ext = fileName.split('.').last.toLowerCase();
      if (['mp3', 'wav', 'm4a', 'ogg', 'aac'].contains(ext)) {
        type = 'media_audio';
      }"""

content = content.replace(target, replacement)

with open('lib/chat_page.dart', 'w', encoding='utf-8') as f:
    f.write(content)

print("Applied media_audio upload type logic!")
