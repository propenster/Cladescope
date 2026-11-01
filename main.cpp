#include <QFileInfo>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include "tree.h"
#include "appbridge.h"

int main(int argc, char *argv[])
{
    // Custom-styled controls need the "Basic" style on every platform.
    qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");

    QGuiApplication app(argc, argv);
    app.setOrganizationName("qTree");
    app.setApplicationName("qTree");

    // Honour the user's saved graphics backend (must precede window creation).
    AppBridge::applyStartupBackend();

    // A tree file passed on the command line ("Open with…", clade in new window)
    QString startFile;
    const QStringList args = app.arguments();
    if (args.size() > 1 && QFileInfo::exists(args.at(1)))
        startFile = QFileInfo(args.at(1)).absoluteFilePath();

    QQmlApplicationEngine engine;
    qmlRegisterType<TreeModel>("com.qtree.backend", 1, 0, "TreeModel");

    AppBridge bridge(startFile);
    engine.rootContext()->setContextProperty("appBridge", &bridge);

    QObject::connect(
        &engine,
        &QQmlApplicationEngine::objectCreationFailed,
        &app,
        []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);
    engine.loadFromModule("quickTree", "Main");

    if (!engine.rootObjects().isEmpty()) {
        if (auto *win = qobject_cast<QQuickWindow *>(engine.rootObjects().first()))
            bridge.attach(win);
    }

    return QGuiApplication::exec();
}
