# Shake gallery permission design

## Goal
Make the shake-to-analyze flow reliably read the latest gallery image on Android, clearly distinguish permission failures from image-availability failures, and guide the user through enabling gallery access without unexpected navigation.

## Scope
This design covers the Android shake-triggered gallery flow initiated from `HomeScreen`. It includes permission declaration, runtime permission handling, user messaging, settings redirection, and success/failure branching before navigation to `ChatScreen`.

Out of scope:
- Changing shake sensitivity, cooldown, or gesture rules
- Altering the AI upload/analyze flow after a valid image path is obtained
- Adding automatic retry after returning from system settings
- Changing the double-tap camera capture flow

## Current problem
The shake flow calls `PhotoManager.requestPermissionExtend()` and, on failure, returns `null` from `_pickLatestGalleryImagePath()`. The caller treats that the same as “no usable image found”, so the user only sees a generic failure message.

On Android, the app currently does not declare gallery read permissions in `android/app/src/main/AndroidManifest.xml`, so the system has no permission to grant and does not present a runtime prompt. This makes repeated shake attempts fail silently from the user’s perspective.

## Chosen approach
Adopt a permission-first flow in `HomeScreen`:
1. Check/request gallery permission when shake capture begins.
2. If permission is granted, read the latest gallery image.
3. Only navigate to `ChatScreen` when an image path is found.
4. If permission is denied or permanently denied, keep the user on the home screen and present a dialog with `去设置` and `取消`.
5. After the user returns from system settings, do not auto-retry; require another shake gesture.

This approach matches the desired UX: explicit permission guidance, no misleading fallback into image-analysis UI, and no surprise navigation after returning from settings.

## Platform changes
### Android manifest
Add the following permission declarations to `android/app/src/main/AndroidManifest.xml`:

- `android.permission.READ_MEDIA_IMAGES`
- `android.permission.READ_EXTERNAL_STORAGE` with `android:maxSdkVersion="32"`

This supports Android 13+ and older Android versions that still depend on external-storage read permission.

## Runtime flow design
### Entry point
`_handleShakeCapture()` remains the single entry point after shake detection succeeds. Its responsibilities change from “vibrate, fetch image, navigate” to “vibrate, resolve gallery access, fetch image, navigate if successful”.

### Permission resolution
Replace the current opaque `String?`-only outcome with an explicit flow result that distinguishes:
- permission granted + image found
- permission granted + no readable image found
- permission denied
- permission permanently denied or otherwise restricted

This can be modeled either as a small enum + payload object or an equivalent internal structure. The key requirement is that `HomeScreen` must know *why* image resolution failed before deciding what to show.

### Success path
When permission is granted and a readable latest image is found:
- keep the existing vibration behavior
- pass the resolved path into `ChatScreen(captureSource: CaptureSource.shake, imagePath: latestPath)`
- allow the existing `ChatScreen -> DoubaoApiService` analysis flow to run unchanged

### Denied path
When permission is denied or permanently denied:
- do not navigate to `ChatScreen`
- show a modal dialog on the home screen
- dialog content explains that gallery permission is required to read the most recent image for shake-triggered recognition
- buttons are `去设置` and `取消`

`去设置` opens the app’s system settings page. `取消` dismisses the dialog and leaves the user on the home screen.

### No-image path
When permission is granted but no readable image is found:
- do not show the permission dialog
- do not navigate to `ChatScreen`
- show a short message equivalent to the current “未读取到可用图片” behavior

This keeps permission failures and content-availability failures distinct.

## Return-from-settings behavior
After the user taps `去设置` and later returns to the app:
- do not automatically re-run the gallery read
- do not automatically navigate to `ChatScreen`
- leave the user on the home screen
- require the user to shake again

This avoids surprising transitions after the app regains focus and keeps the trigger model consistent.

## UI copy guidance
### Permission dialog
Title: `需要相册权限`

Body: Explain that shake-triggered recognition needs gallery access to read the most recent photo.

Actions:
- `去设置`
- `取消`

### Cancel feedback
After the user cancels, show a short message indicating that gallery permission is not enabled and the image cannot be read.

### No-image feedback
Retain a concise message equivalent to `未读取到可用图片` for the case where permission exists but no image can be read.

## Code touchpoints
### `android/app/src/main/AndroidManifest.xml`
Add Android gallery read permissions.

### `lib/screens/home_screen.dart`
Primary implementation file. Expected changes:
- refactor `_pickLatestGalleryImagePath()` into a result-returning helper or split helpers for permission + image lookup
- update `_handleShakeCapture()` to branch on explicit outcomes
- add home-screen dialog presentation for denied/permanently denied permission states
- add settings redirection behavior
- keep existing shake detection, vibration timing, and navigation destination unchanged where not required by this feature

### `lib/screens/chat_screen.dart`
No behavior change required. It already uploads and analyzes the provided `imagePath`.

### `lib/services/doubao_api_service.dart`
No behavior change required for this feature.

## Error handling
- If permission API returns a restricted or limited state that does not allow actual gallery reads, treat it as a non-success permission outcome unless image reading is verified to work.
- If image enumeration returns albums but no readable backing file, treat that as “no readable image found”, not as a permission failure.
- If settings redirection cannot be opened for some reason, fall back to staying on the home screen and showing a short failure message.

## Testing
### Manual test cases
1. Fresh install, no gallery permission yet:
   - shake once
   - system permission prompt appears
   - grant permission
   - latest image is read and analysis screen opens

2. Fresh install, deny permission:
   - shake once
   - system prompt appears
   - deny permission
   - permission dialog with `去设置 / 取消` appears
   - tap `取消`
   - stay on home screen

3. Permission permanently denied:
   - shake again after permanent denial
   - permission dialog appears without entering analysis screen
   - tap `去设置`
   - app settings open

4. Return from settings after enabling permission:
   - return to app
   - remain on home screen
   - shake again
   - latest image is read and analysis screen opens

5. Permission granted but no readable image:
   - shake once
   - stay on home screen
   - show no-image message only

6. Existing success path:
   - permission already granted and readable image exists
   - shake once
   - normal navigation and AI analysis still work

## Non-goals and constraints
- No automatic resume or deferred retry state is stored across app background/foreground transitions.
- No changes are made to the double-tap camera flow because it does not depend on gallery permission.
- No changes are made to AI prompting, image compression, or response handling as part of this permission fix.

## Recommendation summary
Implement the complete permission-first flow in `HomeScreen`, add the missing Android permission declarations, and keep the user on the home screen when permission is unavailable. This is the clearest and least surprising behavior for shake-triggered gallery analysis.