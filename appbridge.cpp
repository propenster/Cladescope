#include "appbridge.h"

#include <QClipboard>
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QImage>
#include <QMarginsF>
#include <QOpenGLContext>
#include <QOpenGLFunctions>
#include <QPageSize>
#include <QPainter>
#include <QPdfWriter>
#include <QProcess>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSettings>
#include <QSvgRenderer>
#include <QTextStream>
#include <QFileInfo>

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

constexpr int kMaxRecent = 10;
#ifdef Q_OS_WIN
constexpr Qt::CaseSensitivity kPathCase = Qt::CaseInsensitive;
#else
constexpr Qt::CaseSensitivity kPathCase = Qt::CaseSensitive;
#endif
QString cleanAbs(const QString &p) { return QDir::cleanPath(QFileInfo(p).absoluteFilePath()); }

} // namespace

AppBridge::AppBridge(const QString &startupFile, QObject *parent)
    : QObject(parent), m_startupFile(startupFile) {}

void AppBridge::applyStartupBackend()
{
    QSettings s("cladescope", "cladescope");
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
    QSettings s("cladescope", "cladescope");
    return s.value("graphics/backend", "auto").toString();
}

void AppBridge::setBackendPref(const QString &pref)
{
    QSettings s("cladescope", "cladescope");
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

// ------------------------------------------------------------ figure export

bool AppBridge::saveText(const QString &path, const QString &text)
{
    QFile f(path);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Text)) return false;
    QTextStream out(&f);
    out << text;
    return true;
}

bool AppBridge::renderPdf(const QString &path, const QString &svg)
{
    QSvgRenderer renderer(svg.toUtf8());
    if (!renderer.isValid()) return false;

    QSizeF size = renderer.viewBoxF().size();
    if (size.isEmpty()) return false;

    // PDF pages are limited to 14400 pt; scale very large trees down to fit.
    const qreal maxDim = 14000.0;
    const qreal k = qMin<qreal>(1.0, maxDim / qMax(size.width(), size.height()));
    const QSizeF page(size.width() * k, size.height() * k);

    QPdfWriter pdf(path);
    pdf.setResolution(72);
    pdf.setPageSize(QPageSize(page, QPageSize::Point));
    pdf.setPageMargins(QMarginsF(0, 0, 0, 0));
    pdf.setCreator("cladescope");

    QPainter p(&pdf);
    if (!p.isActive()) return false;
    p.setRenderHint(QPainter::Antialiasing);
    p.setRenderHint(QPainter::TextAntialiasing);
    renderer.render(&p, QRectF(QPointF(0, 0), page));
    p.end();
    return true;
}

bool AppBridge::renderPng(const QString &path, const QString &svg, double scale)
{
    QSvgRenderer renderer(svg.toUtf8());
    if (!renderer.isValid()) return false;

    const QSizeF size = renderer.viewBoxF().size();
    if (size.isEmpty()) return false;

    qreal s = qMax(0.25, scale);
    // keep the bitmap within sane limits
    while ((size.width() * s > 20000 || size.height() * s > 20000
            || size.width() * s * size.height() * s > 1.5e8) && s > 0.1)
        s *= 0.85;

    QImage img(QSize(qRound(size.width() * s), qRound(size.height() * s)), QImage::Format_ARGB32);
    if (img.isNull()) return false;
    img.fill(Qt::white);
    QPainter p(&img);
    p.setRenderHint(QPainter::Antialiasing);
    p.setRenderHint(QPainter::TextAntialiasing);
    renderer.render(&p, QRectF(QPointF(0, 0), QSizeF(img.size())));
    p.end();
    return img.save(path);
}

bool AppBridge::openNewWindow(const QString &newick, const QString &name)
{
    const QString path = QDir::temp().filePath(
        QString("cladescope_%1_%2.nwk").arg(name).arg(QDateTime::currentMSecsSinceEpoch()));
    if (!saveText(path, newick + "\n")) return false;
    return QProcess::startDetached(QCoreApplication::applicationFilePath(), QStringList() << path);
}

QStringList AppBridge::recentFiles() const
{
    QSettings s("Cladescope", "Cladescope");
    QStringList out;
    const QStringList stored = s.value("recent/files").toStringList();
    for (const QString &p : stored) out << QDir::toNativeSeparators(p);
    return out;
}

void AppBridge::addRecent(const QString &path)
{
    const QString abs = cleanAbs(path);
    if (abs.isEmpty()) return;
    // clades sent to a new window live in the temp folder; keep them out of the list
    if (QFileInfo(abs).fileName().startsWith("cladescope_")
        && abs.startsWith(QDir::cleanPath(QDir::tempPath()), kPathCase)) return;
    QSettings s("Cladescope", "Cladescope");
    QStringList list = s.value("recent/files").toStringList();
    for (int i = list.size() - 1; i >= 0; --i)
        if (QString::compare(list.at(i), abs, kPathCase) == 0) list.removeAt(i);
    list.prepend(abs);
    while (list.size() > kMaxRecent) list.removeLast();
    s.setValue("recent/files", list);
    emit recentChanged();
}

void AppBridge::removeRecent(const QString &path)
{
    const QString abs = cleanAbs(path);
    QSettings s("Cladescope", "Cladescope");
    QStringList list = s.value("recent/files").toStringList();
    for (int i = list.size() - 1; i >= 0; --i)
        if (QString::compare(list.at(i), abs, kPathCase) == 0) list.removeAt(i);
    s.setValue("recent/files", list);
    emit recentChanged();
}

void AppBridge::clearRecent()
{
    QSettings s("Cladescope", "Cladescope");
    s.remove("recent/files");
    emit recentChanged();
}

bool AppBridge::fileExists(const QString &path) const
{
    return QFileInfo(path).isFile();
}

bool AppBridge::openFileInNewWindow(const QString &path)
{
    return QProcess::startDetached(QCoreApplication::applicationFilePath(), QStringList() << path);
}
