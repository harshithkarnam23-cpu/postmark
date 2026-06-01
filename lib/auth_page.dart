import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:desktop_webview_auth/desktop_webview_auth.dart';
import 'package:desktop_webview_auth/google.dart';
import 'registration_wizard.dart';
import 'home_page.dart';
import 'legal_terms_page.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  bool _obscurePassword = true;
  bool _isEmailLoading = false;
  bool _isGoogleLoading = false;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signInWithEmail() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      _showError('Please enter both email and password.');
      return;
    }

    setState(() => _isEmailLoading = true);
    try {
      // Check if user is registered in Firestore details
      final snapshot = await FirebaseFirestore.instance
          .collection('userdetails')
          .where('email', isEqualTo: email)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) {
        // Not registered! Redirect to wizard with their input email/password
        setState(() => _isEmailLoading = false);
        if (!mounted) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => RegistrationWizard(
              email: email,
              tempPassword: password,
            ),
          ),
        );
        return;
      }

      // Already registered! Proceed to sign in normally
      final userCredential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      await _handlePostSignIn(userCredential);
    } catch (e) {
      _showError(_getErrorMessage(e));
    } finally {
      if (mounted) setState(() => _isEmailLoading = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() => _isGoogleLoading = true);
    try {
      OAuthCredential credential;

      if (!kIsWeb && Platform.isWindows) {
        const String webClientId =
            '1063270362786-jq4jj1hejaqjb48e5o2hjepcs10juhtr.apps.googleusercontent.com';

        final result = await DesktopWebviewAuth.signIn(
          GoogleSignInArgs(
            clientId: webClientId,
            redirectUri: 'https://postmark-d39c7.firebaseapp.com/__/auth/handler',
            scope: 'email',
          ),
        );

        if (result == null) {
          setState(() => _isGoogleLoading = false);
          return;
        }

        credential = GoogleAuthProvider.credential(
          accessToken: result.accessToken,
          idToken: result.idToken,
        );
      } else {
        final googleSignIn = GoogleSignIn(
          serverClientId:
              '1063270362786-jq4jj1hejaqjb48e5o2hjepcs10juhtr.apps.googleusercontent.com',
        );

        // Force Google Account Picker to show every time
        await googleSignIn.signOut();
        final GoogleSignInAccount? googleUser = await googleSignIn.signIn();

        if (googleUser == null) {
          setState(() => _isGoogleLoading = false);
          return;
        }

        final GoogleSignInAuthentication googleAuth = await googleUser.authentication;

        credential = GoogleAuthProvider.credential(
          accessToken: googleAuth.accessToken,
          idToken: googleAuth.idToken,
        );
      }

      final UserCredential userCredential =
          await FirebaseAuth.instance.signInWithCredential(credential);

      await _handlePostSignIn(userCredential);
    } catch (e) {
      _showError(_getErrorMessage(e));
    } finally {
      if (mounted) setState(() => _isGoogleLoading = false);
    }
  }

  Future<void> _handlePostSignIn(UserCredential userCredential) async {
    final String email = userCredential.user?.email ?? '';

    // Check if profile is completed in Firestore
    final querySnapshot = await FirebaseFirestore.instance
        .collection('userdetails')
        .where('email', isEqualTo: email)
        .limit(1)
        .get();

    if (!mounted) return;

    if (querySnapshot.docs.isNotEmpty) {
      // Profile exists — go to Home
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => const HomePage()),
        (route) => false,
      );
    } else {
      // Profile incomplete — go to Registration Wizard
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (context) => RegistrationWizard(userCredential: userCredential),
        ),
        (route) => false,
      );
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  String _getErrorMessage(dynamic e) {
    final String message = e.toString();

    if (e is FirebaseAuthException) {
      switch (e.code) {
        case 'email-already-in-use':
          return 'This email address is already registered. Try logging in.';
        case 'invalid-email':
          return 'Please enter a valid email address.';
        case 'weak-password':
          return 'Your password is too weak. Please use at least 6 characters.';
        case 'operation-not-allowed':
          return 'Sign-in option not enabled. Please contact support.';
        case 'network-request-failed':
          return 'Network connection error. Please check your internet connection.';
        case 'credential-already-in-use':
          return 'This Google account is already linked to another user.';
        case 'account-exists-with-different-credential':
          return 'An account already exists with this email but using a different sign-in method.';
        default:
          if (message.contains(']')) {
            return message.substring(message.indexOf(']') + 1).trim();
          }
          return e.message ?? 'An unexpected authentication error occurred.';
      }
    }

    if (e is FirebaseException) {
      if (e.code == 'permission-denied') {
        return 'You do not have permission to perform this action.';
      }
      if (message.contains(']')) {
        return message.substring(message.indexOf(']') + 1).trim();
      }
      return e.message ?? 'A database error occurred. Please try again.';
    }

    if (message.contains(']')) {
      return message.substring(message.indexOf(']') + 1).trim();
    }

    if (message.contains('firebase') || message.contains('Firebase')) {
      return 'An unexpected connection error occurred. Please try again.';
    }

    return message;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      body: SafeArea(
        child: Align(
          alignment: const Alignment(0.0, -0.3),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Logo
                SizedBox(
                  height: 160,
                  child: OverflowBox(
                    maxHeight: 240,
                    alignment: Alignment.topCenter,
                    child: Transform.translate(
                      offset: const Offset(0, -20),
                      child: Image.asset('assets/logo.png'),
                    ),
                  ),
                ),

                // Subtitle
                const Text(
                  'Sign in to continue',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFFB3B3B3),
                    fontSize: 16,
                  ),
                ),

                const SizedBox(height: 24),

                // Email Field
                _buildInputCapsule(
                  hintText: 'Email',
                  icon: Icons.email_outlined,
                  controller: _emailController,
                ),

                const SizedBox(height: 8),

                // Password Field
                _buildInputCapsule(
                  hintText: 'Password',
                  icon: Icons.lock_outline,
                  controller: _passwordController,
                  isPassword: true,
                ),

                const SizedBox(height: 24),

                // Sign In Button
                SizedBox(
                  height: 54,
                  child: ElevatedButton(
                    onPressed: _isEmailLoading ? null : _signInWithEmail,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0A84FF),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(27),
                      ),
                      elevation: 0,
                    ),
                    child: _isEmailLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text(
                            'Sign In',
                            style: TextStyle(fontSize: 16),
                          ),
                  ),
                ),

                const SizedBox(height: 16),

                // Divider
                Row(
                  children: [
                    const Expanded(child: Divider(color: Color(0xFF333333), thickness: 1)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'or',
                        style: TextStyle(color: Colors.grey[600], fontSize: 14),
                      ),
                    ),
                    const Expanded(child: Divider(color: Color(0xFF333333), thickness: 1)),
                  ],
                ),

                const SizedBox(height: 16),

                // Google Sign In Button
                SizedBox(
                  height: 54,
                  child: OutlinedButton(
                    onPressed: _isGoogleLoading ? null : _signInWithGoogle,
                    style: OutlinedButton.styleFrom(
                      backgroundColor: const Color(0xFF1C1C1E),
                      side: const BorderSide(color: Color(0xFF2C2C2E), width: 1.2),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(27),
                      ),
                    ),
                    child: _isGoogleLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Image.network(
                                'https://upload.wikimedia.org/wikipedia/commons/thumb/c/c1/Google_%22G%22_logo.svg/120px-Google_%22G%22_logo.svg.png',
                                height: 24,
                                width: 24,
                                errorBuilder: (context, error, stackTrace) =>
                                    const Icon(Icons.g_mobiledata, color: Colors.white, size: 32),
                              ),
                              const SizedBox(width: 12),
                              const Text(
                                'Continue with Google',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                  ),
                ),

                const SizedBox(height: 24),

                // Helper text for registration
                const Text(
                  'to register to postmark click on continue with google',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF8E8E93),
                    fontSize: 13.5,
                    fontWeight: FontWeight.w400,
                  ),
                ),

                const SizedBox(height: 12),

                // Footer with interactive links
                _buildFooterText(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFooterText(BuildContext context) {
    return Center(
      child: RichText(
        textAlign: TextAlign.center,
        text: TextSpan(
          style: const TextStyle(
            color: Color(0xFF808080),
            fontSize: 13,
            height: 1.45,
          ),
          children: [
            const TextSpan(text: 'By signing in, you agree to the PostMark\n'),
            TextSpan(
              text: 'Terms of Service',
              style: const TextStyle(
                color: Color(0xFF007AFF),
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.underline,
              ),
              recognizer: TapGestureRecognizer()
                ..onTap = () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const LegalTermsPage()),
                  );
                },
            ),
            const TextSpan(text: ' and '),
            TextSpan(
              text: 'Privacy Policy',
              style: const TextStyle(
                color: Color(0xFF007AFF),
                fontWeight: FontWeight.w500,
                decoration: TextDecoration.underline,
              ),
              recognizer: TapGestureRecognizer()
                ..onTap = () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const LegalTermsPage()),
                  );
                },
            ),
            const TextSpan(text: '.'),
          ],
        ),
      ),
    );
  }

  Widget _buildInputCapsule({
    required String hintText,
    required IconData icon,
    required TextEditingController controller,
    bool isPassword = false,
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
              obscureText: isPassword ? _obscurePassword : false,
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
              onTap: () {
                setState(() {
                  _obscurePassword = !_obscurePassword;
                });
              },
              child: Icon(
                _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                color: const Color(0xFF8E8E93),
                size: 20,
              ),
            ),
        ],
      ),
    );
  }
}
