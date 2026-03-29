# Scenes

Scenes is a native macOS menu bar app for setting up repeatable workspace layouts and launch flows from `.scene` files.

## What it does

- Auto-discovers `.scene` files from `~/Scenes`
- Lets you run scenes from the menu bar
- Opens `.scene` documents when you click them in Finder
- Supports a first set of actions:
  - launch an app
  - open a URL
  - run a shell command
  - wait for a delay
  - move and resize the frontmost window of an app

## Development

1. Generate the Xcode project:

   ```bash
   xcodegen generate
   ```

2. Open `Scenes.xcodeproj` or build from the command line:

   ```bash
   xcodebuild -project Scenes.xcodeproj -scheme Scenes -configuration Debug build
   ```

3. Create a scene directory:

   ```bash
   mkdir -p ~/Scenes
   cp Examples/Demo.scene ~/Scenes/
   ```

## Scene format

Scenes uses JSON with a `.scene` extension.

```json
{
  "name": "Demo State",
  "steps": [
    {
      "type": "launchApp",
      "applicationName": "Terminal"
    },
    {
      "type": "delay",
      "seconds": 1.0
    },
    {
      "type": "runShellCommand",
      "command": "echo hello from Scenes"
    },
    {
      "type": "moveWindow",
      "applicationName": "Terminal",
      "x": 40,
      "y": 60,
      "width": 900,
      "height": 700
    }
  ]
}
```

## Permissions

Window movement uses the macOS Accessibility API. The app will prompt for Accessibility access when needed.
