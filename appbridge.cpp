#include "appbridge.h"

#include <QClipboard>
#include <QCoreApplication>
#include <QGuiApplication>
#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QProcess>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSettings>

namespace {
QString apiName(QSGRendererInterface::GraphicsApi a)
{
    switch (a) {
    case QSGRendererInterface::OpenGL:      return QStringLiteral("OpenGL");
    case QSGRendererInterface::Direct3D11:  return QStringLiteral("Direct3D 11");
    case QSGRendererInterface::Vulkan:      return QStringLiteral("Vulkan");
    case QSGRendererInterface::Metal:       return QStringLiteral("Metal");
    case QSGRendererInterface::Software:    return QStringLiteral("Software");
    default:                                return QStringLiteral("Unknown");
    }
}
} // namespace

AppBridge::AppBridge(QObject *parent) : QObject(parent) {}

void AppBridge::applyStartupBackend()
{
    QSettings s("qTree", "qTree");
    const QString pref = s.value("graphics/backend", "auto").toString();
    if (pref == "opengl")
        QQuickWindow::setGraphicsApi(QSGRendererInterface::OpenGL);
    else if (pref == "software")
        QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);
}

void AppBridge::attach(QQuickWindow *w)
{
    if (!w) return;

    // Emitted on the render thread with the GL context current (if GL is used).
    connect(w, &QQuickWindow::sceneGraphInitialized, this, [this, w]() {
        const QString api = apiName(w->rendererInterface()->graphicsApi());
        QString gpu;
        if (QOpenGLContext *ctx = QOpenGLContext::currentContext()) {
            const GLubyte *r = ctx->functions()->glGetString(GL_RENDERER);
            if (r) gpu = QString::fromLatin1(reinterpret_cast<const char *>(r));
        }
        QMetaObject::invokeMethod(this, [this, api, gpu]() { updateInfo(api, gpu); },
                                  Qt::QueuedConnection);
    }, Qt::DirectConnection);

    if (w->isSceneGraphInitialized() && w->rendererInterface())
        updateInfo(apiName(w->rendererInterface()->graphicsApi()), QString());
}

void AppBridge::updateInfo(const QString &api, const QString &gpu)
{
    m_api = api;
    m_gpu = gpu.trimmed();
    const QString low = m_gpu.toLower();
    const bool softRenderer = low.contains("llvmpipe") || low.contains("softpipe")
                              || low.contains("swiftshader") || low.contains("software")
                              || low.contains("basic render");
    m_hardware = (api != "Software" && api != "Unknown") && !softRenderer;
    m_canGpuCanvas = (api == "OpenGL") && m_hardware;
    emit infoChanged();
}

QString AppBridge::backendPref() const
{
    QSettings s("qTree", "qTree");
    return s.value("graphics/backend", "auto").toString();
}

void AppBridge::setBackendPref(const QString &pref)
{
    QSettings s("qTree", "qTree");
    s.setValue("graphics/backend", pref);
    emit prefChanged();
}

void AppBridge::copyText(const QString &text)
{
    QGuiApplication::clipboard()->setText(text);
}

void AppBridge::restart()
{
    QProcess::startDetached(QCoreApplication::applicationFilePath(),
                            QCoreApplication::arguments().mid(1));
    QCoreApplication::quit();
}
