#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QIcon>

int main(int argc, char *argv[])
{
    qputenv("QML2_IMPORT_PATH", "/usr/lib/qt5/qml");
    qputenv("QML2_IMPORT_DIR",  "/usr/lib/qt5/qml");

    QGuiApplication app(argc, argv);
    app.setApplicationName("harbour-sfsmoke");
    app.setOrganizationName("sailfish");
    app.setApplicationVersion("0.1.0");

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("version", app.applicationVersion());
    engine.load(QUrl(QStringLiteral("qrc:/main.qml")));
    if (engine.rootObjects().isEmpty())
        return -1;

    return app.exec();
}
