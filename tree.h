#ifndef TREE_H
#define TREE_H

#include <QHash>
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
    Q_PROPERTY(QVariantMap metadata READ metadata NOTIFY metadataChanged)
    Q_PROPERTY(bool canUndo READ canUndo NOTIFY undoChanged)

public:
    explicit TreeModel(QObject *parent = nullptr);
    ~TreeModel() override;

    QString fileName() const { return m_fileName; }
    QVariantMap treeData() const { return m_treeData; }
    bool loading() const { return m_loading; }
    int tipCount() const { return m_tree.tipCount; }
    int nodeCount() const { return m_tree.names.size(); }
    QVariantMap metadata() const { return m_metadata; }
    bool canUndo() const { return !m_undo.isEmpty(); }

    // loading / saving
    Q_INVOKABLE void loadFile(const QUrl &fileUrl);
    Q_INVOKABLE void loadPath(const QString &path);
    Q_INVOKABLE void loadExample();
    Q_INVOKABLE bool saveNewick(const QUrl &fileUrl);
    Q_INVOKABLE QString localPath(const QUrl &url) const;

    // metadata (CSV / TSV). Column values reach QML aligned to node indices.
    Q_INVOKABLE void loadMetadata(const QUrl &fileUrl);
    Q_INVOKABLE void clearMetadata();

    // tree editing (all undoable)
    Q_INVOKABLE void rerootAt(int node);       // reroot on the branch above `node`
    Q_INVOKABLE void midpointRoot();
    Q_INVOKABLE void extractClade(int node);   // replace tree with the clade below `node`
    Q_INVOKABLE QString subtreeNewick(int node) const;
    Q_INVOKABLE void undo();

signals:
    void loadStarted(const QString &name);
    void progress(const QString &stage, double fraction);
    void treeLoaded();
    void loadingChanged();
    void errorOccurred(const QString &message);
    void metadataChanged();
    void metadataLoaded(int matched, int total, const QString &key);
    void undoChanged();
    void edited(const QString &message);

private:
    void startJob(const QString &displayName, const QString &path, const QString &inlineText);
    void finishLoad(const QString &displayName, const ParsedTree &tree);
    void rebuildTreeData();
    void commitTree(const ParsedTree &tree, const QString &fileName, const QString &message);
    void applyEdit(const ParsedTree &tree, const QString &message, const QString &fileName = QString());
    void publishMetadata();

    ParsedTree m_tree;
    QVector<ParsedTree> m_undo;
    QString m_fileName;
    QVariantMap m_treeData;
    bool m_loading = false;
    QPointer<QThread> m_thread;

    // metadata is keyed by tip *name*, so it survives reroot / extract / undo
    QStringList m_metaColumns;
    QHash<QString, QStringList> m_metaRows;
    QString m_metaKey;
    int m_metaTotal = 0;
    QVariantMap m_metadata;
};

#endif // TREE_H
