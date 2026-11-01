#ifndef APPBRIDGE_H
#define APPBRIDGE_H

#include <QObject>
#include <QString>

class QQuickWindow;

// Bridge between QML and the platform:
//  * clipboard
//  * which Qt Quick graphics backend / GPU is in use (+ persisted preference)
//  * figure export: SVG text -> .svg / .pdf / .png
//  * opening a clade in a second app window
class AppBridge : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString api READ api NOTIFY infoChanged)
    Q_PROPERTY(QString gpuName READ gpuName NOTIFY infoChanged)
    Q_PROPERTY(bool hardware READ hardware NOTIFY infoChanged)
    Q_PROPERTY(bool canGpuCanvas READ canGpuCanvas NOTIFY infoChanged)
    Q_PROPERTY(QString backendPref READ backendPref NOTIFY prefChanged)
    Q_PROPERTY(QString startupFile READ startupFile CONSTANT)

public:
    explicit AppBridge(const QString &startupFile = QString(), QObject *parent = nullptr);

    // Call after QGuiApplication exists but BEFORE any window is created.
    static void applyStartupBackend();
    // Call once the root window exists.
    void attach(QQuickWindow *window);

    QString api() const { return m_api; }
    QString gpuName() const { return m_gpu; }
    bool hardware() const { return m_hardware; }
    bool canGpuCanvas() const { return m_canGpuCanvas; }
    QString backendPref() const;
    QString startupFile() const { return m_startupFile; }

    Q_INVOKABLE void copyText(const QString &text);
    Q_INVOKABLE void setBackendPref(const QString &pref); // auto | opengl | software
    Q_INVOKABLE void restart();

    // figure export (svg is the SVG document text produced by the canvas)
    Q_INVOKABLE bool saveText(const QString &path, const QString &text);
    Q_INVOKABLE bool renderPdf(const QString &path, const QString &svg);
    Q_INVOKABLE bool renderPng(const QString &path, const QString &svg, double scale);

    // write a Newick string to a temp file and open it in a new app instance
    Q_INVOKABLE bool openNewWindow(const QString &newick, const QString &name);

signals:
    void infoChanged();
    void prefChanged();

private:
    void updateInfo(const QString &api, const QString &gpu);

    QString m_api;
    QString m_gpu;
    QString m_startupFile;
    bool m_hardware = false;
    bool m_canGpuCanvas = false;
};

#endif // APPBRIDGE_H
