%define name harbour-sfsmoke
%define version 0.1.0
%define release 1

Name:           %{name}
Version:        %{version}
Release:        %{release}
Summary:        Smoke-test canary app (tap counter) for the Bionic SFOS skill
License:        GPL-3.0
URL:            https://example.invalid/harbour-sfsmoke
Group:          Applications/Utility

Requires:       qt5-qtdeclarative
Requires:       qt5-qtquick

%description
Dedicated MINIMAL canary app for scripts/smoke.sh (tier T2).
Lay-out contract (do not change without updating smoke.sh):
  - one big bold "TAPS: <n>" label, centered on the whole screen
  - the whole screen is a MouseArea that increments the counter on press
The smoke test proves the input pipeline by a pixel-diff of the centered
region across three taps.

%prep
# Nothing to unpack — sources are taken from the build tree.

%build
cd rpm/sources
qmake harbour-sfsmoke.pro
make

%install
rm -rf %{buildroot}

# ── Directories ──────────────────────────────────────────────
install -d %{buildroot}/usr/bin
install -d %{buildroot}/usr/share/harbour-sfsmoke
install -d %{buildroot}/usr/share/applications

# ── C++ binary (built into rpm/sources by make) ──────────────
install -m 755 rpm/sources/harbour-sfsmoke %{buildroot}/usr/bin/harbour-sfsmoke

# ── manifest.json ────────────────────────────────────────────
install -m 644 rpm/sources/manifest.json %{buildroot}/usr/share/harbour-sfsmoke/

# ── .desktop file (required: app drawer + sailjail launch) ───
cat > %{buildroot}/usr/share/applications/harbour-sfsmoke.desktop <<'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=harbour-sfsmoke
Exec=harbour-sfsmoke
Comment=Smoke-test canary (tap counter)
DESKTOP

%files
%attr(755, root, root) /usr/bin/harbour-sfsmoke
/usr/share/harbour-sfsmoke/*
/usr/share/applications/harbour-sfsmoke.desktop
