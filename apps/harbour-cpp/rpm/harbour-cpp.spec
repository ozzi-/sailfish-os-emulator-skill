%define name harbour-cpp
%define version 0.1.0
%define release 2

Name:           %{name}
Version:        %{version}
Release:        %{release}
Summary:        Minimal Harbour C++ app — Bionic pipeline test
License:        GPL-3.0
URL:            https://example.invalid/harbour-cpp
Group:          Applications/Utility

Requires:       qt5-qtdeclarative
Requires:       qt5-qtquick

%description
A minimal Harbour app with a real C++ entry point (qmake + make on the
engine). Verifies cross-compilation and binary deploy to the emulator.

%prep
# Nothing to unpack — sources are taken from the build tree.

%build
cd rpm/sources
qmake harbour-cpp.pro
make

%install
rm -rf %{buildroot}

# ── Directories ──────────────────────────────────────────────
install -d %{buildroot}/usr/bin
install -d %{buildroot}/usr/share/harbour-cpp
install -d %{buildroot}/usr/share/applications

# ── C++ binary (built into rpm/sources by make) ──────────────
install -m 755 rpm/sources/harbour-cpp %{buildroot}/usr/bin/harbour-cpp

# ── manifest.json ────────────────────────────────────────────
install -m 644 rpm/sources/manifest.json %{buildroot}/usr/share/harbour-cpp/

# ── .desktop file (required: app drawer + sailjail launch) ───
cat > %{buildroot}/usr/share/applications/harbour-cpp.desktop <<'DESKTOP'
[Desktop Entry]
Version=1.0
Type=Application
Name=harbour-cpp
Exec=harbour-cpp
Comment=Bionic C++ pipeline test
DESKTOP

%files
%attr(755, root, root) /usr/bin/harbour-cpp
/usr/share/harbour-cpp/*
/usr/share/applications/harbour-cpp.desktop
