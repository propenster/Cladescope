#include <QFileInfo>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include "tree.h"
#include "appbridge.h"
#include <QIcon>
#include <QPalette>
#include <QStyleHints>

int main(int argc, char *argv[])
{
    // Custom-styled controls need the "Basic" style on every platform.
    qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");

    QGuiApplication app(argc, argv);
    app.setOrganizationName("cladescope");
    app.setApplicationName("cladescope");
    QIcon icon;
    for (int s : {16, 32, 48, 64, 128, 256, 512})
        icon.addFile(QString(":/icons/cladescope-C-%1.png").arg(s), QSize(s, s));
    app.setWindowIcon(icon);

    // Honour the user's saved graphics backend (must precede window creation).
    AppBridge::applyStartupBackend();

    // A tree file passed on the command line ("Open with…", clade in new window)
    QString startFile;
    const QStringList args = app.arguments();
    if (args.size() > 1 && QFileInfo::exists(args.at(1)))
        startFile = QFileInfo(args.at(1)).absoluteFilePath();

    app.styleHints()->setColorScheme(Qt::ColorScheme::Light);
    QPalette p;
    p.setColor(QPalette::Window,          "#ffffff");
    p.setColor(QPalette::WindowText,      "#1c2128");
    p.setColor(QPalette::Base,            "#ffffff");
    p.setColor(QPalette::AlternateBase,   "#f6f7f9");
    p.setColor(QPalette::Text,            "#1c2128");
    p.setColor(QPalette::Button,          "#eef1f5");
    p.setColor(QPalette::ButtonText,      "#1c2128");
    p.setColor(QPalette::Highlight,       "#2f6fed");
    p.setColor(QPalette::HighlightedText, "#ffffff");
    p.setColor(QPalette::Mid,             "#d9dde3");
    p.setColor(QPalette::Dark,            "#b9c0c9");
    p.setColor(QPalette::Light,           "#ffffff");
    p.setColor(QPalette::PlaceholderText, "#6b7480");
    p.setColor(QPalette::ToolTipBase,     "#1c2128");
    p.setColor(QPalette::ToolTipText,     "#ffffff");
    app.setPalette(p);

    QQmlApplicationEngine engine;
    qmlRegisterType<TreeModel>("com.cladescope.backend", 1, 0, "TreeModel");

    AppBridge bridge(startFile);
    engine.rootContext()->setContextProperty("appBridge", &bridge);

    QObject::connect(
        &engine,
        &QQmlApplicationEngine::objectCreationFailed,
        &app,
        []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);
    engine.loadFromModule("cladescope", "Main");

    if (!engine.rootObjects().isEmpty()) {
        if (auto *win = qobject_cast<QQuickWindow *>(engine.rootObjects().first()))
            bridge.attach(win);
    }

    return QGuiApplication::exec();
}
