#include "tree.h"

#include <QFile>
#include <QHash>
#include <QMetaObject>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QTextStream>
#include <QThread>
#include <functional>

namespace {

typedef std::function<void(const QString &, double)> Report;

bool isDelimiter(QChar c)
{
    return c == '(' || c == ')' || c == ',' || c == ':' || c == ';' || c == '[';
}

// Iterative Newick parser. Handles quoted labels, [comments], scientific
// notation branch lengths and internal node labels (e.g. support values).
ParsedTree parseNewick(const QString &text, const std::function<void(double)> &progress)
{
    ParsedTree t;
    auto addNode = [&t](int parent) -> int {
        t.names.append(QString());
        t.lengths.append(0.0);
        t.parents.append(parent);
        return t.names.size() - 1;
    };

    int cur = addNode(-1);
    QVector<int> stack;
    const int n = text.size();
    const int reportStep = qMax(1, n / 25);
    int nextReport = reportStep;
    int i = 0;

    while (i < n) {
        if (i >= nextReport) {
            nextReport += reportStep;
            if (progress) progress(double(i) / double(n));
        }
        const QChar c = text.at(i);

        if (c.isSpace()) { ++i; continue; }

        if (c == '[') { // comment, may be nested
            int depth = 0;
            while (i < n) {
                const QChar d = text.at(i++);
                if (d == '[') ++depth;
                else if (d == ']' && --depth == 0) break;
            }
            continue;
        }
        if (c == ';') break;

        if (c == '(') {
            const int node = addNode(cur);
            stack.append(cur);
            cur = node;
            ++i;
            continue;
        }
        if (c == ')') {
            if (stack.isEmpty()) {
                t.error = "Unbalanced parentheses: unexpected ')'.";
                return t;
            }
            cur = stack.takeLast();
            ++i;
            continue;
        }
        if (c == ',') {
            if (t.parents[cur] < 0) {
                t.error = "Malformed Newick: comma outside parentheses.";
                return t;
            }
            const int node = addNode(t.parents[cur]);
            cur = node;
            ++i;
            continue;
        }
        if (c == ':') {
            ++i;
            while (i < n && text.at(i).isSpace()) ++i;
            const int s = i;
            while (i < n && (text.at(i).isDigit() || text.at(i) == '.' || text.at(i) == '-'
                             || text.at(i) == '+' || text.at(i) == 'e' || text.at(i) == 'E'))
                ++i;
            t.lengths[cur] = text.mid(s, i - s).toDouble();
            continue;
        }

        // Label (quoted or bare)
        QString label;
        if (c == '\'') {
            ++i;
            while (i < n) {
                if (text.at(i) == '\'') {
                    if (i + 1 < n && text.at(i + 1) == '\'') { label += '\''; i += 2; continue; }
                    ++i;
                    break;
                }
                label += text.at(i++);
            }
        } else {
            const int s = i;
            while (i < n && !isDelimiter(text.at(i))) ++i;
            label = text.mid(s, i - s).trimmed();
        }
        t.names[cur] = label;
    }

    if (!stack.isEmpty())
        t.error = "Unbalanced parentheses: missing ')'.";
    return t;
}

// Pulls the first tree (and the optional TRANSLATE table) out of a NEXUS file.
QString extractNexusTree(const QString &content, QHash<QString, QString> &translate)
{
    QRegularExpression trRe("\\btranslate\\b(.*?);",
                            QRegularExpression::CaseInsensitiveOption
                                | QRegularExpression::DotMatchesEverythingOption);
    const QRegularExpressionMatch tm = trRe.match(content);
    if (tm.hasMatch()) {
        const QStringList entries = tm.captured(1).split(',', Qt::SkipEmptyParts);
        for (const QString &entry : entries) {
            const QString e = entry.trimmed();
            const int sp = e.indexOf(QRegularExpression("\\s"));
            if (sp <= 0) continue;
            QString key = e.left(sp);
            QString val = e.mid(sp).trimmed();
            if (val.size() >= 2 && val.startsWith('\'') && val.endsWith('\''))
                val = val.mid(1, val.size() - 2);
            translate.insert(key, val);
        }
    }

    QRegularExpression treeRe("\\btree\\s+\\*?\\s*(?:'[^']*'|[^\\s=]+)\\s*=",
                              QRegularExpression::CaseInsensitiveOption);
    const QRegularExpressionMatch m = treeRe.match(content);
    if (!m.hasMatch()) return QString();
    const int start = m.capturedEnd();
    const int end = content.indexOf(';', start);
    return content.mid(start, end < 0 ? -1 : end - start).trimmed();
}

ParsedTree loadAndParse(const QString &path, const QString &inlineText, const Report &report)
{
    ParsedTree fail;
    QString content = inlineText;

    if (!path.isEmpty()) {
        report("Reading file", 0.05);
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
            fail.error = "Could not open file: " + path;
            return fail;
        }
        QTextStream in(&file);
        content = in.readAll();
    }

    content = content.trimmed();
    if (content.isEmpty()) {
        fail.error = "The file is empty.";
        return fail;
    }

    report("Detecting format", 0.18);
    QHash<QString, QString> translate;
    if (content.startsWith("#NEXUS", Qt::CaseInsensitive)) {
        report("Reading Nexus block", 0.22);
        content = extractNexusTree(content, translate);
        if (content.isEmpty()) {
            fail.error = "No tree found in the Nexus file.";
            return fail;
        }
    }

    ParsedTree t = parseNewick(content, [&report](double f) { report("Parsing branches", 0.25 + 0.55 * f); });
    if (!t.error.isEmpty()) return t;
    if (t.names.size() < 2) {
        t.error = "The file does not contain a valid tree.";
        return t;
    }

    report("Resolving taxa", 0.82);
    QVector<char> hasChild(t.names.size(), 0);
    for (int i = 1; i < t.names.size(); ++i) hasChild[t.parents[i]] = 1;
    int tips = 0;
    for (int i = 0; i < t.names.size(); ++i) {
        if (hasChild[i]) continue;
        ++tips;
        if (!translate.isEmpty()) {
            auto it = translate.constFind(t.names[i]);
            if (it != translate.constEnd()) t.names[i] = it.value();
        }
    }
    t.tipCount = tips;
    report("Indexing nodes", 0.88);
    return t;
}

// ---- demo tree (clade-correlated "regions" so pattern colouring looks good) ----
QString demoClade(QRandomGenerator &rng, int tips, int region, int &counter)
{
    static const QStringList regions = {"Kenya", "Brazil", "India", "USA", "China", "UK", "Peru"};
    auto len = [&rng]() { return QString::number(0.01 + rng.generateDouble() * 0.09, 'f', 4); };
    if (tips == 1) {
        return QString("Sample%1_%2_%3:%4")
            .arg(++counter)
            .arg(regions[region])
            .arg(2015 + int(rng.bounded(9)))
            .arg(len());
    }
    const int left = 1 + int(rng.bounded(tips - 1));
    const int rr = rng.bounded(100) < 12 ? int(rng.bounded(regions.size())) : region;
    return "(" + demoClade(rng, left, region, counter) + "," + demoClade(rng, tips - left, rr, counter)
           + ")" + QString::number(60 + int(rng.bounded(40))) + ":" + len();
}

QString quoteLabel(const QString &s)
{
    if (s.isEmpty()) return s;
    static const QString special = " ()[]:;,'";
    for (QChar c : s) {
        if (special.contains(c)) {
            QString q = s;
            q.replace("'", "''");
            return "'" + q + "'";
        }
    }
    return s;
}

} // namespace

// -----------------------------------------------------------------------------

TreeModel::TreeModel(QObject *parent) : QObject(parent) {}

TreeModel::~TreeModel()
{
    if (m_thread) m_thread->wait();
}

QString TreeModel::localPath(const QUrl &url) const
{
    return url.isLocalFile() ? url.toLocalFile() : url.toString();
}

void TreeModel::loadFile(const QUrl &fileUrl)
{
    startJob(fileUrl.fileName(), localPath(fileUrl), QString());
}

void TreeModel::loadExample()
{
    QRandomGenerator rng(20260101);
    int counter = 0;
    const QString nwk = demoClade(rng, 64, 0, counter) + ";";
    startJob("example.nwk", QString(), nwk);
}

void TreeModel::startJob(const QString &displayName, const QString &path, const QString &inlineText)
{
    if (m_loading) return;
    m_loading = true;
    emit loadingChanged();
    emit loadStarted(displayName);

    QThread *thread = QThread::create([this, displayName, path, inlineText]() {
        Report report = [this](const QString &stage, double f) {
            QMetaObject::invokeMethod(this, [this, stage, f]() { emit progress(stage, f); },
                                      Qt::QueuedConnection);
        };
        ParsedTree result = loadAndParse(path, inlineText, report);
        QMetaObject::invokeMethod(this, [this, displayName, result]() { finishLoad(displayName, result); },
                                  Qt::QueuedConnection);
    });
    m_thread = thread;
    connect(thread, &QThread::finished, thread, &QObject::deleteLater);
    thread->start();
}

void TreeModel::finishLoad(const QString &displayName, const ParsedTree &tree)
{
    m_loading = false;
    emit loadingChanged();

    if (!tree.isValid()) {
        emit errorOccurred(tree.error.isEmpty() ? QStringLiteral("The file does not contain a valid tree.")
                                                : tree.error);
        return;
    }

    m_tree = tree;
    m_fileName = displayName;

    QVariantList parents, lengths;
    parents.reserve(tree.parents.size());
    lengths.reserve(tree.lengths.size());
    for (int p : tree.parents) parents.append(p);
    for (double l : tree.lengths) lengths.append(l);

    QVariantMap map;
    map["count"] = tree.names.size();
    map["names"] = tree.names;
    map["parents"] = parents;
    map["lengths"] = lengths;
    m_treeData = map;

    emit progress("Preparing view", 0.9);
    emit treeLoaded();
}

QString TreeModel::toNewick() const
{
    const int n = m_tree.names.size();
    QVector<QVector<int>> children(n);
    for (int i = 1; i < n; ++i) children[m_tree.parents[i]].append(i);

    struct Frame { int node; int next; };
    QVector<Frame> st;
    st.append(Frame{0, 0});
    QString out;

    while (!st.isEmpty()) {
        const int fi = st.size() - 1;
        const int node = st[fi].node;
        const QVector<int> &ch = children[node];
        if (st[fi].next == 0 && !ch.isEmpty()) out += QLatin1Char('(');
        if (st[fi].next < ch.size()) {
            if (st[fi].next > 0) out += QLatin1Char(',');
            const int child = ch[st[fi].next++];
            st.append(Frame{child, 0});
        } else {
            if (!ch.isEmpty()) out += QLatin1Char(')');
            out += quoteLabel(m_tree.names[node]);
            if (node != 0 && m_tree.lengths[node] > 0) {
                out += QLatin1Char(':');
                out += QString::number(m_tree.lengths[node], 'g', 12);
            }
            st.removeLast();
        }
    }
    out += QLatin1Char(';');
    return out;
}

bool TreeModel::saveNewick(const QUrl &fileUrl)
{
    if (m_tree.names.size() < 2) return false;
    QFile file(localPath(fileUrl));
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text)) {
        emit errorOccurred("Could not write file: " + file.fileName());
        return false;
    }
    QTextStream out(&file);
    out << toNewick() << "\n";
    return true;
}
