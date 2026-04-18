# cosmic-panel-guardian
A lightweight user level service for Pop!_OS COSMIC that watches for dock and top bar failures and automatically restarts cosmic-panel when it stops rendering correctly, especially after suspend/resume, without rebooting your session.

To install this service, simply run:
```
curl -fsSL https://raw.githubusercontent.com/MagnetosphereLabs/cosmic-panel-guardian/main/panel-guardian.sh | bash -s -- install
```

To update this service:
```
curl -fsSL https://raw.githubusercontent.com/MagnetosphereLabs/cosmic-panel-guardian/main/panel-guardian.sh | bash -s -- update
```

To uninstall this service:
```
curl -fsSL https://raw.githubusercontent.com/MagnetosphereLabs/cosmic-panel-guardian/main/panel-guardian.sh | bash -s -- uninstall
```

To check the health of this service:
```
curl -fsSL https://raw.githubusercontent.com/MagnetosphereLabs/cosmic-panel-guardian/main/panel-guardian.sh | bash -s -- status
```

To check the logs of this service:
```
curl -fsSL https://raw.githubusercontent.com/MagnetosphereLabs/cosmic-panel-guardian/main/panel-guardian.sh | bash -s -- logs
```
