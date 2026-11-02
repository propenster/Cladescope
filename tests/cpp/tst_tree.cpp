#include <QCoreApplication>
#include <QTest>
// Built only with -DCLADESCOPE_BUILD_TESTS=ON.  Run:  ctest --output-on-failure
// The tests check *invariants* (e.g. rerooting preserves every pairwise tip distance) plus a few
// hand-computed values, so they do not depend on any particular internal representation.
#include <QtTest>
#include <QElapsedTimer>
#include <QFile>
#include <QHash>
#include <QSet>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QTextStream>
#include <cmath>

#include "tree.h"

namespace {

QString fixture(const QString &name) { return QStringLiteral(FIXTURE_DIR) + "/" + name; }

// Flat snapshot of the model's current tree (from treeData: count, names, parents, lengths).
struct Snap {
    QStringList names;
    QVector<int> parent;
    QVector<double> len;
    QVector<int> nChildren;
    int n() const { return names.size(); }
    bool isTip(int i) const { return nChildren[i] == 0; }
};

Snap snapshot(const TreeModel &m)
{
    const QVariantMap d = m.treeData();
    Snap s;
    s.names = d.value("names").toStringList();
    for (const QVariant &v : d.value("parents").toList()) s.parent.append(v.toInt());
    for (const QVariant &v : d.value("lengths").toList()) s.len.append(v.toDouble());
    s.nChildren.fill(0, s.names.size());
    for (int i = 0; i < s.n(); ++i)
        if (s.parent[i] >= 0) s.nChildren[s.parent[i]]++;
    return s;
}

QVector<double> rootDepths(const Snap &s)
{
    QVector<double> depth(s.n(), 0.0);
    for (int i = 1; i < s.n(); ++i) depth[i] = depth[s.parent[i]] + s.len[i];
    return depth;
}

QStringList tipNames(const Snap &s)
{
    QStringList t;
    for (int i = 0; i < s.n(); ++i) if (s.isTip(i)) t << s.names[i];
    t.sort();
    return t;
}

// all pairwise tip distances keyed "a|b" (a<b); tip names must be unique
QHash<QString, double> distances(const Snap &s)
{
    const QVector<double> depth = rootDepths(s);
    QVector<int> tips;
    for (int i = 0; i < s.n(); ++i) if (s.isTip(i)) tips << i;
    QHash<QString, double> out;
    for (int x = 0; x < tips.size(); ++x) {
        QHash<int, bool> anc;
        for (int v = tips[x]; v >= 0; v = s.parent[v]) anc.insert(v, true);
        for (int y = x + 1; y < tips.size(); ++y) {
            int v = tips[y];
            while (!anc.contains(v)) v = s.parent[v];
            const double d = depth[tips[x]] + depth[tips[y]] - 2 * depth[v];
            QString a = s.names[tips[x]], b = s.names[tips[y]];
            if (a > b) std::swap(a, b);
            out.insert(a + "|" + b, d);
        }
    }
    return out;
}

bool sameDistances(const QHash<QString, double> &a, const QHash<QString, double> &b, double tol = 1e-9)
{
    if (a.size() != b.size()) return false;
    for (auto it = a.constBegin(); it != a.constEnd(); ++it) {
        if (!b.contains(it.key())) return false;
        if (std::fabs(b.value(it.key()) - it.value()) > tol * qMax(1.0, std::fabs(it.value()))) return false;
    }
    return true;
}

bool loadAndWait(TreeModel &m, const QString &path, int timeoutMs = 30000)
{
    QSignalSpy ok(&m, &TreeModel::treeLoaded);
    QSignalSpy bad(&m, &TreeModel::errorOccurred);
    m.loadPath(path);
    QElapsedTimer t; t.start();
    while (ok.isEmpty() && bad.isEmpty() && t.elapsed() < timeoutMs) QTest::qWait(5);
    return !ok.isEmpty();
}

QString newickText(TreeModel &m, const QString &dir)
{
    const QString p = dir + "/out.nwk";
    if (!m.saveNewick(QUrl::fromLocalFile(p))) return QString();
    QFile f(p);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text)) return QString();
    return QTextStream(&f).readAll();
}

double maxDepthUnder(const Snap &s, const QVector<double> &depth, int child)
{
    double best = 0;
    for (int i = 0; i < s.n(); ++i) {
        if (!s.isTip(i)) continue;
        for (int v = i; v >= 0; v = s.parent[v])
            if (v == child) { best = qMax(best, depth[i]); break; }
    }
    return best;
}

} // namespace

class TstTree : public QObject {
    Q_OBJECT
private slots:
    void parsesNewick();
    void parsesNexusWithTranslateAndComments();
    void rejectsUnbalancedParentheses();
    void roundTripsThroughSave();
    void rerootPreservesAllTipDistances();
    void undoRestoresExactTree();
    void midpointRootBalancesTheLongestPath();
    void extractKeepsCladeAndDistances();
    void undoStackIsLimitedToTen();
    void subtreeNewickIsLoadable();
    void metadataMatchesAndSurvivesEdits();
    void metadataWithNoMatchingColumnIsRejected();
    void deepLadderTreeDoesNotOverflowTheStack();
};

void TstTree::parsesNewick()
{
    TreeModel m;
    QVERIFY(loadAndWait(m, fixture("small.nwk")));
    QCOMPARE(m.tipCount(), 8);
    QCOMPARE(m.nodeCount(), 13);
    const Snap s = snapshot(m);
    const auto d = distances(s);
    QVERIFY(std::fabs(d.value("A_x|H_w") - 1.3) < 1e-9);
    QVERIFY(std::fabs(d.value("A_x|C_y") - 0.9) < 1e-9);
    QVERIFY(std::fabs(d.value("E_z|G_z") - 0.5) < 1e-9);
}

void TstTree::parsesNexusWithTranslateAndComments()
{
    TreeModel m;
    QVERIFY(loadAndWait(m, fixture("nexus_translate.nex")));
    QCOMPARE(m.tipCount(), 4);
    const Snap s = snapshot(m);
    QCOMPARE(tipNames(s), (QStringList{ "C", "D", "Taxon A|1", "Taxon B" }));
    const auto d = distances(s);                       // includes scientific-notation lengths (1.0E-1, 5E-1)
    QVERIFY(std::fabs(d.value("Taxon A|1|Taxon B") - 0.3) < 1e-9);
    QVERIFY(std::fabs(d.value("C|Taxon A|1") - 0.9) < 1e-9);
    QVERIFY(std::fabs(d.value("C|D") - 0.9) < 1e-9);
}

void TstTree::rejectsUnbalancedParentheses()
{
    TreeModel m;
    QSignalSpy bad(&m, &TreeModel::errorOccurred);
    QSignalSpy ok(&m, &TreeModel::treeLoaded);
    m.loadPath(fixture("unbalanced.nwk"));
    QVERIFY(bad.wait(10000));
    QCOMPARE(ok.count(), 0);
    QCOMPARE(m.tipCount(), 0);
}

void TstTree::roundTripsThroughSave()
{
    QTemporaryDir dir; QVERIFY(dir.isValid());
    TreeModel a;
    QVERIFY(loadAndWait(a, fixture("small.nwk")));
    const QString text = newickText(a, dir.path());
    QVERIFY(!text.isEmpty());
    TreeModel b;
    QVERIFY(loadAndWait(b, dir.path() + "/out.nwk"));
    QCOMPARE(tipNames(snapshot(a)), tipNames(snapshot(b)));
    QVERIFY(sameDistances(distances(snapshot(a)), distances(snapshot(b))));
}

void TstTree::rerootPreservesAllTipDistances()
{
    TreeModel m;
    QVERIFY(loadAndWait(m, fixture("small.nwk")));
    const Snap before = snapshot(m);
    const auto d0 = distances(before);
    for (int node = 1; node < before.n(); ++node) {
        m.rerootAt(node);
        const Snap after = snapshot(m);
        QCOMPARE(m.tipCount(), 8);
        QCOMPARE(tipNames(after), tipNames(before));
        QVERIFY2(sameDistances(distances(after), d0), qPrintable(QString("distances changed after rerooting on node %1").arg(node)));
        m.undo();
    }
}

void TstTree::undoRestoresExactTree()
{
    QTemporaryDir dir; QVERIFY(dir.isValid());
    TreeModel m;
    QVERIFY(loadAndWait(m, fixture("small.nwk")));
    const QString original = newickText(m, dir.path());
    QVERIFY(!m.canUndo());
    m.rerootAt(5);
    QVERIFY(m.canUndo());
    QVERIFY(newickText(m, dir.path()) != original);
    m.undo();
    QCOMPARE(newickText(m, dir.path()), original);
    QVERIFY(!m.canUndo());
}

void TstTree::midpointRootBalancesTheLongestPath()
{
    TreeModel m;
    QVERIFY(loadAndWait(m, fixture("small.nwk")));
    const auto d0 = distances(snapshot(m));
    m.midpointRoot();
    const Snap s = snapshot(m);
    QVERIFY(sameDistances(distances(s), d0));
    const QVector<double> depth = rootDepths(s);
    QVector<double> reach;                              // deepest tip under each child of the root
    for (int i = 1; i < s.n(); ++i) if (s.parent[i] == 0) reach << maxDepthUnder(s, depth, i);
    QVERIFY(reach.size() >= 2);
    std::sort(reach.begin(), reach.end(), std::greater<double>());
    QVERIFY2(std::fabs(reach[0] - reach[1]) < 1e-9, "the two longest root-to-tip paths must be equal at the midpoint");
}

void TstTree::extractKeepsCladeAndDistances()
{
    TreeModel m;
    QVERIFY(loadAndWait(m, fixture("small.nwk")));
    const Snap before = snapshot(m);
    const auto d0 = distances(before);
    const QString oldName = m.fileName();
    // the clade holding E_z, F_z, G_z: parent of the node named E_z
    const int e = before.names.indexOf("E_z");
    const int clade = before.parent[e];
    QStringList expected;
    for (int i = 0; i < before.n(); ++i) {
        if (!before.isTip(i)) continue;
        for (int v = i; v >= 0; v = before.parent[v]) if (v == clade) { expected << before.names[i]; break; }
    }
    expected.sort();
    m.extractClade(clade);
    const Snap after = snapshot(m);
    QCOMPARE(tipNames(after), expected);
    QCOMPARE(m.tipCount(), 3);
    QVERIFY(m.fileName().endsWith(" (clade)"));
    const auto d1 = distances(after);
    for (auto it = d1.constBegin(); it != d1.constEnd(); ++it)
        QVERIFY(std::fabs(it.value() - d0.value(it.key())) < 1e-9);
    m.undo();
    QCOMPARE(m.tipCount(), 8);
}

void TstTree::undoStackIsLimitedToTen()
{
    TreeModel m;
    QVERIFY(loadAndWait(m, fixture("small.nwk")));
    QSignalSpy edits(&m, &TreeModel::edited);
    for (int i = 0; i < 14; ++i) m.rerootAt(1 + (i % 5));
    QVERIFY2(edits.count() >= 11, "need more than 10 successful edits to test the limit");
    int undone = 0;
    while (m.canUndo() && undone < 100) { m.undo(); ++undone; }
    QCOMPARE(undone, 10);
    m.undo();                                           // no-op, must not crash
    QCOMPARE(m.tipCount(), 8);
}

void TstTree::subtreeNewickIsLoadable()
{
    QTemporaryDir dir; QVERIFY(dir.isValid());
    TreeModel m;
    QVERIFY(loadAndWait(m, fixture("small.nwk")));
    const Snap s = snapshot(m);
    const int clade = s.parent[s.names.indexOf("C_y")];
    const QString nwk = m.subtreeNewick(clade);
    QVERIFY(!nwk.isEmpty());
    QFile f(dir.path() + "/clade.nwk");
    QVERIFY(f.open(QIODevice::WriteOnly | QIODevice::Text));
    QTextStream(&f) << nwk << "\n";
    f.close();
    TreeModel sub;
    QVERIFY(loadAndWait(sub, dir.path() + "/clade.nwk"));
    QCOMPARE(tipNames(snapshot(sub)), (QStringList{ "C_y", "D_y" }));
    QVERIFY(m.subtreeNewick(-1).isEmpty());
    QVERIFY(m.subtreeNewick(9999).isEmpty());
}

void TstTree::metadataMatchesAndSurvivesEdits()
{
    TreeModel m;
    QVERIFY(loadAndWait(m, fixture("small.nwk")));
    QSignalSpy loaded(&m, &TreeModel::metadataLoaded);
    m.loadMetadata(QUrl::fromLocalFile(fixture("meta.csv")));
    QCOMPARE(loaded.count(), 1);
    QCOMPARE(loaded.at(0).at(0).toInt(), 4);            // 4 of the 5 rows match a tip
    QCOMPARE(loaded.at(0).at(1).toInt(), 5);
    QCOMPARE(loaded.at(0).at(2).toString(), QString("strain"));

    auto countryOf = [&](const QString &tip) {
        const Snap s = snapshot(m);
        const QVariantMap md = m.metadata();
        const QStringList cols = md.value("columns").toStringList();
        const int c = cols.indexOf("country");
        if (c < 0) return QString("<no column>");
        const QStringList vals = md.value("values").toList().at(c).toStringList();
        const int idx = s.names.indexOf(tip);
        return idx >= 0 && idx < vals.size() ? vals.at(idx) : QString("<no tip>");
    };
    QCOMPARE(m.metadata().value("columns").toStringList(), (QStringList{ "country", "year", "host" }));
    QCOMPARE(countryOf("A_x"), QString("Kenya"));
    QCOMPARE(countryOf("C_y"), QString("Peru"));
    QCOMPARE(countryOf("H_w"), QString(""));            // tip with no metadata row

    m.rerootAt(7);                                      // node indices change, metadata must follow tip names
    QCOMPARE(countryOf("A_x"), QString("Kenya"));
    QCOMPARE(countryOf("E_z"), QString("Peru"));
    m.midpointRoot();
    QCOMPARE(countryOf("B_x"), QString("Kenya"));

    m.clearMetadata();
    QVERIFY(m.metadata().value("columns").toStringList().isEmpty());
}

void TstTree::metadataWithNoMatchingColumnIsRejected()
{
    TreeModel m;
    QVERIFY(loadAndWait(m, fixture("small.nwk")));
    QSignalSpy bad(&m, &TreeModel::errorOccurred);
    m.loadMetadata(QUrl::fromLocalFile(fixture("meta_nomatch.csv")));
    QCOMPARE(bad.count(), 1);
    QVERIFY(m.metadata().value("columns").toStringList().isEmpty());
}

void TstTree::deepLadderTreeDoesNotOverflowTheStack()
{
    const int L = 50000;
    QTemporaryDir dir; QVERIFY(dir.isValid());
    const QString path = dir.path() + "/ladder.nwk";
    {
        QFile f(path);
        QVERIFY(f.open(QIODevice::WriteOnly | QIODevice::Text));
        QTextStream out(&f);
        out << QString(L - 1, QChar('(')) << "x0:1";
        for (int i = 1; i < L; ++i) out << ",x" << i << ":1)";
        out << ";\n";
    }
    TreeModel m;
    QElapsedTimer t; t.start();
    QVERIFY(loadAndWait(m, path, 60000));
    QCOMPARE(m.tipCount(), L);
    QCOMPARE(m.nodeCount(), 2 * L - 1);
    m.rerootAt(m.nodeCount() / 2);                      // iterative reroot on a very deep tree
    QCOMPARE(m.tipCount(), L);
    m.midpointRoot();
    QCOMPARE(m.tipCount(), L);
    QVERIFY2(t.elapsed() < 60000, "deep tree handling is too slow");
}

QTEST_GUILESS_MAIN(TstTree)
#include "tst_tree.moc"
