#ifndef TREE_H
#define TREE_H

#include <QObject>
#include <QPointer>
#include <QString>
#include <QStringList>
#include <QUrl>
#include <QVariantMap>
#include <QVector>

class QThread;

// Flat, pre-order representation of a tree. A node's parent always has a
// smaller index than the node itself, so subtrees are contiguous ranges and
// no recursion is needed anywhere (safe for very deep / huge trees).
struct ParsedTree {
    QStringList names;
    QVector<double> lengths;
    QVector<int> parents;
    QString error;
    int tipCount = 0;
    bool isValid() const { return error.isEmpty() && names.size() > 1; }
};

class TreeModel : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString fileName READ fileName NOTIFY treeLoaded)
    Q_PROPERTY(QVariantMap treeData READ treeData NOTIFY treeLoaded)
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
    Q_PROPERTY(int tipCount READ tipCount NOTIFY treeLoaded)
    Q_PROPERTY(int nodeCount READ nodeCount NOTIFY treeLoaded)

public:
    explicit TreeModel(QObject *parent = nullptr);
    ~TreeModel() override;

    QString fileName() const { return m_fileName; }
    QVariantMap treeData() const { return m_treeData; }
    bool loading() const { return m_loading; }
    int tipCount() const { return m_tree.tipCount; }
    int nodeCount() const { return m_tree.names.size(); }

    Q_INVOKABLE void loadFile(const QUrl &fileUrl);
    Q_INVOKABLE void loadExample();
    Q_INVOKABLE bool saveNewick(const QUrl &fileUrl);
    Q_INVOKABLE QString localPath(const QUrl &url) const;

signals:
    void loadStarted(const QString &name);
    void progress(const QString &stage, double fraction);
    void treeLoaded();
    void loadingChanged();
    void errorOccurred(const QString &message);

private:
    void startJob(const QString &displayName, const QString &path, const QString &inlineText);
    void finishLoad(const QString &displayName, const ParsedTree &tree);
    QString toNewick() const;

    ParsedTree m_tree;
    QString m_fileName;
    QVariantMap m_treeData;
    bool m_loading = false;
    QPointer<QThread> m_thread;
};

#endif // TREE_H
