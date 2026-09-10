import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart'; // NEW
import 'dart:typed_data';

class StudentUploadScreen extends StatefulWidget {
  const StudentUploadScreen({super.key});

  @override
  State<StudentUploadScreen> createState() => _StudentUploadScreenState();
}

class _StudentUploadScreenState extends State<StudentUploadScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  String? _selectedCourse;
  String? _selectedExamType;
  Uint8List? _fileBytes;
  String? _fileName;
  bool _isUploading = false;
  
  final supabase = Supabase.instance.client;
  final firestore = FirebaseFirestore.instance;
  final uuid = const Uuid();

  List<String> courses = ['Maths', 'Physics', 'Chemistry', 'Biology'];

  @override
  void initState() {
    super.initState();
    _loadSubjects();
  }

  Future<void> _loadSubjects() async {
    try {
      DocumentSnapshot doc = await firestore.collection('settings').doc('app').get();
      if (doc.exists) {
        var data = doc.data() as Map<String, dynamic>?;
        if (data!= null && data['subjects']!= null) {
          setState(() {
            courses = List<String>.from(data['subjects']);
          });
        }
      }
    } catch (e) {
      debugPrint("Load subjects error: $e");
    }
  }

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'png', 'docx'],
      withData: true, // IMPORTANT: gets bytes for web
    );
    if (result!= null) {
      setState(() {
        _fileBytes = result.files.single.bytes;
        _fileName = result.files.single.name;
      });
    }
  }

  Future<void> _saveToLocalHistory(String fileName) async { // NEW
    final prefs = await SharedPreferences.getInstance();
    List<String> myUploads = prefs.getStringList('my_uploads')?? [];
    if (!myUploads.contains(fileName)) {
      myUploads.add(fileName);
      await prefs.setStringList('my_uploads', myUploads);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _fileBytes == null || _fileName == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please fill all fields and select a file')));
      return;
    }

    setState(() => _isUploading = true);
    try {
      // 1. Upload file to Supabase Storage
      String uniqueFileName = '${uuid.v4()}_$_fileName';
      String storagePath = 'pending_uploads/$uniqueFileName';
      
      await supabase.storage.from('examhook-files').uploadBinary(storagePath, _fileBytes!);
      
      String fileUrl = supabase.storage.from('examhook-files').getPublicUrl(storagePath);

      // 2. Save to Firestore pending collection
      await firestore.collection('resources_pending').add({
        'title': _titleController.text,
        'course': _selectedCourse,
        'examType': _selectedExamType,
        'fileUrl': fileUrl,
        'fileName': storagePath, // full path for delete + tracking
        'fileSize': _fileBytes!.length,
        'uploadedAt': FieldValue.serverTimestamp(),
        'status': 'pending',
        'likes': 0,
        'downloads': 0,
        'rating': 0.0,
        'ratingCount': 0,
      });

      // 3. Save to local history for "My Uploads" tab // NEW
      await _saveToLocalHistory(storagePath);

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Upload sent for review!'), backgroundColor: Colors.green));
      Navigator.pop(context);
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e'), backgroundColor: Colors.red));
    }
    setState(() => _isUploading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Upload Resource', style: GoogleFonts.poppins(fontWeight: FontWeight.bold))),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              TextFormField(controller: _titleController, decoration: const InputDecoration(labelText: 'Title', border: OutlineInputBorder()), validator: (v) => v!.isEmpty? 'Required' : null),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _selectedCourse,
                decoration: const InputDecoration(labelText: 'Subject', border: OutlineInputBorder()),
                items: courses.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                onChanged: (v) => setState(() => _selectedCourse = v),
                validator: (v) => v == null? 'Required' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _selectedExamType,
                decoration: const InputDecoration(labelText: 'Exam Type', border: OutlineInputBorder()),
                items: ['Past Paper', 'Notes', 'Quiz', 'Assignment'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                onChanged: (v) => setState(() => _selectedExamType = v),
                validator: (v) => v == null? 'Required' : null,
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _pickFile, 
                icon: const Icon(Icons.attach_file), 
                label: Text(_fileName == null? 'Pick File' : _fileName!)
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _isUploading? null : _submit,
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00C896), padding: const EdgeInsets.symmetric(vertical: 16)),
                child: _isUploading? const CircularProgressIndicator(color: Colors.white) : const Text('Submit for Review', style: TextStyle(color: Colors.white, fontSize: 16)),
              )
            ],
          ),
        ),
      ),
    );
  }
}