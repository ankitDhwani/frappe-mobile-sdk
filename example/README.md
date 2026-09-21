# frappe_mobile_sdk example

A runnable demo app for [`frappe_mobile_sdk`](https://pub.dev/packages/frappe_mobile_sdk).
It signs in against a Frappe site over OAuth, lists the doctypes you configure,
and opens each one in the SDK's dynamic form — the same `FormScreen`,
`FrappeFormBuilder` and offline stack a real host app uses.

It always builds against the SDK **in this repository**, not a published
version: `dependency_overrides` in `pubspec.yaml` replaces the source outright,
so changes to `../lib` show up here immediately.

## Setup

Two steps are required before the app will build. Neither is optional and
neither is done for you, because both produce files that are deliberately
gitignored.

### 1. Create the config file

`lib/main.dart` imports `config/app_config.dart`, which is gitignored so that
nobody's server URL or OAuth secret is ever committed. Without it the app does
not compile — `Target of URI doesn't exist: 'config/app_config.dart'`. Copy the
template:

```bash
cd example
cp lib/config/app_config.example.dart lib/config/app_config.dart
```

Then edit `lib/config/app_config.dart`:

| Constant | What to put in it |
|---|---|
| `baseUrl` | Your Frappe site, **with a trailing slash** — `https://your-site.com/` |
| `oauthClientId` | Client ID from the site's OAuth Client record |
| `oauthClientSecret` | Client secret from the same record |
| `appName` | Title shown in the app bar |
| `packageName` | Application id reported to `FrappeAppGuard` |
| `appVersion` | Build version reported to `FrappeAppGuard` |
| `homeScreenLayout` | `list` or `folder` |
| `documentListLayout` | `list` or `card` |
| `formStylePreset` | `standard`, `compact` or `material` |
| `formTabHeaderLayout` | `tabbar` or `stepper` |

The last four exist so you can see each SDK layout option without editing code.
`packageName` and `appVersion` are what `FrappeAppGuard` sends to
`mobile_auth.app_status`, which is how the server tells a build it is too old to
run — set them to values the site actually knows about, or the guard has nothing
to compare against.

> CI does step 1 for you (`.github/workflows/ci.yml` copies the template before
> analyzing), which is why a fresh clone analyzes cleanly on GitHub but not on
> your machine until you run the copy.

### 2. Generate the platform folders

`example/android/` and `example/ios/` are gitignored (see the root
`.gitignore`), so a fresh clone has no native project to build:

```bash
flutter create --platforms=android,ios .
```

This also **rewrites `.metadata`**, which *is* tracked — it rewrites the Flutter
revision and drops the `linux`/`macos`/`web`/`windows` entries. Restore it so the
change does not end up in a commit:

```bash
git checkout -- .metadata
```

### 3. Run

```bash
flutter pub get
flutter run
```

## Location permissions

The SDK stamps `mobile_created_at` and `mobile_latitude_longitude` when a record
is started, and blocks new records on a doctype that declares those fields until
the device can produce a fix. Because `example/android/` is generated rather than
committed, the manifest it produces carries no location permissions and the
capture silently records nothing. Add them to
`android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
```

On iOS, add `NSLocationWhenInUseUsageDescription` to `ios/Runner/Info.plist`.

## Second entry point: the creation-capture probe

`lib/creation_capture_probe.dart` is a device harness rather than part of the
demo. It drives the real offline save path — `FormScreen` → `OfflineRepository`
→ `LocalWriter` → `docs__<doctype>` — with **no server involved**, then reads the
stored row back and shows it, which is the part unit tests cannot prove: a real
clock, a real GPS fix, a real permission prompt, a real `sqflite` write.

```bash
flutter run -t lib/creation_capture_probe.dart -d <device>
```

It needs the location permissions above.

## Using a published SDK instead

To point the example (or your own app) at a release rather than this checkout,
delete the `dependency_overrides` block. The constraint in `dependencies` then
applies, and **the prerelease matters**:

```yaml
dependencies:
  frappe_mobile_sdk: ^2.0.0-beta.3   # takes 2.0.0-beta.3 and every later beta
```

`^2.0.0` would **not** work while the 2.x line is in beta. `2.0.0-beta.4` sorts
*below* `2.0.0`, so `^2.0.0` means `>=2.0.0 <3.0.0` and skips every prerelease.
A lower bound that is itself a prerelease is what admits them —
`^2.0.0-beta.3` is `>=2.0.0-beta.3 <3.0.0`, which takes the later betas and the
eventual 2.0.0 stable.

## Documentation

| Topic | Where |
|---|---|
| Setup and server requirements | [`../doc/SETUP.md`](../doc/SETUP.md) |
| Full API and concepts | [`../doc/DOCUMENTATION.md`](../doc/DOCUMENTATION.md) |
| UI customization | [`../doc/CUSTOMIZATION.md`](../doc/CUSTOMIZATION.md) |
| What shipped in 2.0 | [`../doc/release-2.0/README.md`](../doc/release-2.0/README.md) |
