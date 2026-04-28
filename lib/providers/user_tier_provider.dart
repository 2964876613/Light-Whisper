import 'package:flutter/foundation.dart';

class UserTierProvider extends ChangeNotifier {
  UserTierProvider({required bool isProUser}) : _isProUser = isProUser;

  bool _isProUser;

  bool get isProUser => _isProUser;

  void setProUser(bool value) {
    if (_isProUser == value) return;
    _isProUser = value;
    notifyListeners();
  }
}
