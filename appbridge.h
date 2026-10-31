#ifndef APPBRIDGE_H
#define APPBRIDGE_H

#include <QObject>
#include <QString>

class QQuickWindow;

// Small bridge between QML and the platform:
//  * clipboard access
//  * which Qt Quick graphics backend / GPU is actually in use
//  * a persisted backend preference (applied at next start)
class AppBridge : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString api READ api NOTIFY infoChanged)
    Q_PROPERTY(QString gpuName READ gpuName NOTIFY infoChanged)
    Q_PROPERTY(bool hardware READ hardware NOTIFY infoChanged)
    Q_PROPERTY(bool canGpuCanvas READ canGpuCanvas NOTIFY infoChanged)
    Q_PROPERTY(QString backendPref READ backendPref NOTIFY prefChanged)

public:
    explicit AppBridge(QObject *parent = nullptr);

    // Call after QGuiApplication exists but BEFORE any window is created.
    static void applyStartupBackend();
    // Call once the root window exists.
    void attach(QQuickWindow *window);

    QString api() const { return m_api; }
    QString gpuName() const { return m_gpu; }
    bool hardware() const { return m_hardware; }
    bool canGpuCanvas() const { return m_canGpuCanvas; }
    QString backendPref() const;

    Q_INVOKABLE void copyText(const QString &text);
    Q_INVOKABLE void setBackendPref(const QString &pref); // auto | opengl | software
    Q_INVOKABLE void restart();

signals:
    void infoChanged();
    void prefChanged();

private:
    void updateInfo(const QString &api, const QString &gpu);

    QString m_api;
    QString m_gpu;
    bool m_hardware = false;
    bool m_canGpuCanvas = false;
};

#endif // APPBRIDGE_H
