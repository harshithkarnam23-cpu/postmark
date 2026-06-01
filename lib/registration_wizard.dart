import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/cupertino.dart' show CupertinoDatePicker, CupertinoDatePickerMode;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'auth_page.dart';
import 'home_page.dart';

class RegistrationWizard extends StatefulWidget {
  final UserCredential? userCredential; // Google Sign-In user (null if email flow)
  final String? email;                  // Raw email for email registration
  final String? tempPassword;           // Initial typed password for email registration

  const RegistrationWizard({
    super.key,
    this.userCredential,
    this.email,
    this.tempPassword,
  });

  @override
  State<RegistrationWizard> createState() => _RegistrationWizardState();
}

class _RegistrationWizardState extends State<RegistrationWizard> {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _isLoading = false;

  // Form Controllers & State
  final _usernameController = TextEditingController();
  DateTime _dateOfBirth = DateTime(2000, 1, 1);
  File? _profileImage;
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  // Preset solid colors for avatar background
  final List<Color> _presetColors = [
    const Color(0xFF0A84FF), // Apple System Blue
    const Color(0xFFFF453A), // Apple System Red
    const Color(0xFF30D158), // Apple System Green
    const Color(0xFFFF9F0A), // Apple System Orange
    const Color(0xFFBF5AF2), // Apple System Purple
    const Color(0xFFFF375F), // Apple System Pink
    const Color(0xFF40C8E0), // Apple System Teal
    const Color(0xFF5E5CE6), // Apple System Indigo
  ];

  late Color _selectedAvatarColor;

  // Cloudinary Details
  final String cloudinaryCloudName = 'dtpydep9j';
  final String cloudinaryUploadPreset = 'postmark_preset';

  @override
  void initState() {
    super.initState();
    _selectedAvatarColor = _presetColors[0];
    if (widget.tempPassword != null) {
      _passwordController.text = widget.tempPassword!;
      _confirmPasswordController.text = widget.tempPassword!;
    }
  }

  @override
  void dispose() {
    _pageController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      setState(() {
        _profileImage = File(pickedFile.path);
      });
    }
  }

  Future<String?> _uploadImage(File image) async {
    if (cloudinaryCloudName == 'YOUR_CLOUD_NAME') {
      // Mock upload if Cloudinary is not configured
      await Future.delayed(const Duration(seconds: 1));
      return 'https://via.placeholder.com/150';
    }

    try {
      final url = Uri.parse('https://api.cloudinary.com/v1_1/$cloudinaryCloudName/image/upload');
      final request = http.MultipartRequest('POST', url)
        ..fields['upload_preset'] = cloudinaryUploadPreset
        ..files.add(await http.MultipartFile.fromPath('file', image.path));

      final response = await request.send();
      if (response.statusCode == 200) {
        final responseData = await response.stream.toBytes();
        final responseString = String.fromCharCodes(responseData);
        final jsonMap = jsonDecode(responseString);
        return jsonMap['secure_url'];
      }
    } catch (e) {
      debugPrint('Error uploading image: $e');
    }
    return null;
  }

  Future<void> _cancelAndExit() async {
    setState(() => _isLoading = true);
    try {
      if (widget.userCredential != null) {
        // Delete incomplete Google Auth user
        await FirebaseAuth.instance.currentUser?.delete();
        await FirebaseAuth.instance.signOut();
      }
    } catch (e) {
      debugPrint('Error deleting temporary user: $e');
    }

    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const AuthPage()),
        (route) => false,
      );
    }
  }

  Future<void> _nextPage() async {
    if (_currentPage == 0) {
      // Page 0 validation: Username must be filled and unique
      final username = _usernameController.text.trim();
      if (username.isEmpty) {
        _showError('Please enter a username');
        return;
      }

      setState(() => _isLoading = true);
      try {
        final doc = await FirebaseFirestore.instance.collection('userdetails').doc(username).get();
        if (doc.exists) {
          _showError('This username is already taken. Please choose another one.');
          return;
        }
      } catch (e) {
        _showError('Failed to verify username: $e');
        return;
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }

      _animateToPage(1);
    } else if (_currentPage == 1) {
      // Page 1 has no strict validations (avatar selection is optional)
      _animateToPage(2);
    } else if (_currentPage == 2) {
      // Page 2 validation: Passwords must match and not be empty
      final password = _passwordController.text;
      final confirmPassword = _confirmPasswordController.text;

      if (password.isEmpty || confirmPassword.isEmpty) {
        _showError('Please fill in password fields');
        return;
      }
      if (password != confirmPassword) {
        _showError('Passwords do not match');
        return;
      }
      _completeRegistration();
    }
  }

  void _previousPage() {
    if (_currentPage > 0) {
      _animateToPage(_currentPage - 1);
    } else {
      _cancelAndExit();
    }
  }

  void _animateToPage(int page) {
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _completeRegistration() async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;

    setState(() => _isLoading = true);

    try {
      String? profileImageUrl;
      if (_profileImage != null) {
        profileImageUrl = await _uploadImage(_profileImage!);
      }

      final isGoogle = widget.userCredential != null;
      final email = isGoogle ? (widget.userCredential!.user?.email ?? '') : (widget.email ?? '');

      String uid = '';

      if (isGoogle) {
        // Google Sign-In: We link the Email provider to the existing Google account
        final user = widget.userCredential!.user!;
        uid = user.uid;
        try {
          final emailCredential = EmailAuthProvider.credential(
            email: email,
            password: password,
          );
          await user.linkWithCredential(emailCredential);
        } catch (linkError) {
          debugPrint('Provider link info/error: $linkError');
        }
      } else {
        // Email flow: create the Firebase Auth user ONLY now that details are fully completed
        final userCredential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
        uid = userCredential.user!.uid;
      }

      // Add to Firestore with username as the document ID
      await FirebaseFirestore.instance.collection('userdetails').doc(username).set({
        'uid': uid,
        'email': email,
        'username': username,
        'dateOfBirth': _dateOfBirth.toIso8601String(),
        'profilePictureUrl': profileImageUrl ?? '',
        'avatarColor': '#${_selectedAvatarColor.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
        'password': password,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Registration Complete!')),
      );

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const HomePage()),
        (route) => false,
      );
    } catch (e) {
      _showError('Registration failed: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        _previousPage();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF111111),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: Icon(_currentPage > 0 ? Icons.arrow_back_ios_new : Icons.close, color: Colors.white, size: 20),
            onPressed: _previousPage,
          ),
          title: const Text(
            'Complete Profile',
            style: TextStyle(color: Colors.white, fontSize: 18),
          ),
          centerTitle: true,
        ),
        body: SafeArea(
          child: Column(
            children: [
              // Top Progress indicator lines
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
                child: Row(
                  children: List.generate(3, (index) {
                    final isPassedOrCurrent = index <= _currentPage;
                    return Expanded(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        height: 4,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                          color: isPassedOrCurrent ? const Color(0xFF0A84FF) : const Color(0xFF2C2C2E),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    );
                  }),
                ),
              ),
              const SizedBox(height: 16),

              Expanded(
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(), // Wizard steps navigated via button only
                  onPageChanged: (page) => setState(() => _currentPage = page),
                  children: [
                    _buildPersonalInfoPage(),
                    _buildProfileImagePage(),
                    _buildSecurityPage(),
                  ],
                ),
              ),

              // Bottom control button
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _nextPage,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0A84FF),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(27),
                      ),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : Text(
                            _currentPage == 2 ? 'Complete Registration' : 'Next',
                            style: const TextStyle(fontSize: 16),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // PAGE 0: Profile Image Setup
  Widget _buildProfileImagePage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 24),
          const Text(
            'Choose a Profile Picture',
            style: TextStyle(color: Colors.white, fontSize: 22),
          ),
          const SizedBox(height: 12),
          
          // Clear, premium instruction info card
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF2C2C2E), width: 1.0),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, color: Color(0xFF0A84FF), size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'INSTRUCTION: Please upload a profile picture from your device, or choose any solid background color below for your text avatar.',
                    style: TextStyle(
                      color: Color(0xFFE5E5EA),
                      fontSize: 13.5,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 36),

          GestureDetector(
            onTap: _pickImage,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircleAvatar(
                  radius: 56,
                  backgroundColor: _selectedAvatarColor,
                  backgroundImage: _profileImage != null ? FileImage(_profileImage!) : null,
                  child: _profileImage == null
                      ? Text(
                          _usernameController.text.isNotEmpty
                              ? _usernameController.text.trim()[0].toUpperCase()
                              : 'U',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 48,
                          ),
                        )
                      : null,
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(
                      color: Color(0xFF0A84FF),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.camera_alt,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: _pickImage,
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 20),
            label: const Text('Select Image from Device'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF0A84FF),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
          ),

          const SizedBox(height: 28),
          const Text(
            'Or Select Avatar Solid Color Theme',
            style: TextStyle(color: Colors.white, fontSize: 15),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: _presetColors.map((color) {
              final isSelected = _selectedAvatarColor == color;
              return GestureDetector(
                onTap: () => setState(() => _selectedAvatarColor = color),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected ? Colors.white : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // PAGE 1: Personal Info Page
  Widget _buildPersonalInfoPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 24),
          const Text(
            'Personal Details',
            style: TextStyle(color: Colors.white, fontSize: 22),
          ),
          const SizedBox(height: 8),
          const Text(
            'Enter your preferred username and select your date of birth.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF8E8E93), fontSize: 14),
          ),
          const SizedBox(height: 48),
          _buildTextField(
            controller: _usernameController,
            hintText: 'Username',
            icon: Icons.person_outline,
          ),
          const SizedBox(height: 16),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Date of Birth',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            height: 180,
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF2C2C2E), width: 1.2),
            ),
            child: DefaultTextStyle(
              style: const TextStyle(color: Colors.white, fontSize: 18),
              child: CupertinoDatePicker(
                mode: CupertinoDatePickerMode.date,
                initialDateTime: _dateOfBirth,
                minimumDate: DateTime(1900),
                maximumDate: DateTime.now(),
                onDateTimeChanged: (DateTime newDate) {
                  setState(() => _dateOfBirth = newDate);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // PAGE 2: Security & Password Setup
  Widget _buildSecurityPage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 24),
          const Text(
            'Account Security',
            style: TextStyle(color: Colors.white, fontSize: 22),
          ),
          const SizedBox(height: 8),
          const Text(
            'Create a strong password to protect your PostMark account.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Color(0xFF8E8E93), fontSize: 14),
          ),
          const SizedBox(height: 48),
          _buildTextField(
            controller: _passwordController,
            hintText: 'Password',
            icon: Icons.lock_outline,
            isPassword: true,
            obscureText: _obscurePassword,
            onToggleObscure: () => setState(() => _obscurePassword = !_obscurePassword),
          ),
          const SizedBox(height: 16),
          _buildTextField(
            controller: _confirmPasswordController,
            hintText: 'Confirm Password',
            icon: Icons.lock_outline,
            isPassword: true,
            obscureText: _obscureConfirmPassword,
            onToggleObscure: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hintText,
    required IconData icon,
    bool isPassword = false,
    bool obscureText = false,
    VoidCallback? onToggleObscure,
  }) {
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(27),
        border: Border.all(color: const Color(0xFF2C2C2E), width: 1.2),
      ),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF8E8E93), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscureText,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: InputDecoration(
                hintText: hintText,
                hintStyle: const TextStyle(color: Color(0xFF636366), fontSize: 16),
                border: InputBorder.none,
              ),
            ),
          ),
          if (isPassword)
            GestureDetector(
              onTap: onToggleObscure,
              child: Icon(
                obscureText ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                color: const Color(0xFF8E8E93),
                size: 20,
              ),
            ),
        ],
      ),
    );
  }
}