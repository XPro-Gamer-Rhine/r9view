#include <cstdio>
#include "book.h"
#include "pageprovider.h"

#include <QCommandLineOption>
#include <QCommandLineParser>
#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QSettings>
#include <QTextStream>

#ifdef Q_OS_WIN
#include <fcntl.h>
#include <io.h>
#include <windows.h>
#endif

using namespace Qt::StringLiterals;

#ifdef Q_OS_WIN
// The Windows build is a GUI binary, so Windows gives it no console and every
// write to stdout lands in the void -- which would make --list and --help print
// nothing at all when run from a terminal. Joining the console of whatever
// launched us gives those streams somewhere to go. Launched from Explorer there
// is no parent console, AttachConsole fails, and nothing here matters.
static bool alreadyConnected(DWORD stream)
{
    // A GUI process started from a shell gets a null standard handle unless the
    // shell redirected that stream, so a real handle here means someone already
    // decided where this output goes.
    const HANDLE h = GetStdHandle(stream);
    return h != nullptr && h != INVALID_HANDLE_VALUE;
}

static void attachParentConsole()
{
    // Redirection wins. Pointing stdout back at the console after the shell has
    // aimed it somewhere would break `r9view --list book.cbz > pages.txt`, which
    // is exactly what --list is for.
    const bool haveOut = alreadyConnected(STD_OUTPUT_HANDLE);
    const bool haveErr = alreadyConnected(STD_ERROR_HANDLE);
    if (haveOut && haveErr)
        return;
    if (!AttachConsole(ATTACH_PARENT_PROCESS))
        return;
    FILE *f = nullptr;
    if (!haveOut)
        freopen_s(&f, "CONOUT$", "w", stdout);
    if (!haveErr)
        freopen_s(&f, "CONOUT$", "w", stderr);
}
#endif

// Qt's own log output goes nowhere useful in some desktop sessions, which makes
// a QML warning impossible to see. R9VIEW_DEBUG=1 forces every message straight
// to stderr, unbuffered.
static void stderrLogger(QtMsgType, const QMessageLogContext &context, const QString &message)
{
    fprintf(stderr, "[%s:%d] %s\n", context.file ? context.file : "?", context.line,
            qPrintable(message));
    fflush(stderr);
}

int main(int argc, char *argv[])
{
#ifdef Q_OS_WIN
    attachParentConsole();
    // Keep settings in a file the way the Linux build does, rather than
    // scattering bookmarks through the registry: %APPDATA%/r9view/r9view.ini
    // is one place to look, back up, or delete.
    QSettings::setDefaultFormat(QSettings::IniFormat);
#endif
    if (qEnvironmentVariableIsSet("R9VIEW_DEBUG"))
        qInstallMessageHandler(stderrLogger);
    QGuiApplication app(argc, argv);
    app.setApplicationName(u"r9view"_s);
    app.setOrganizationName(u"r9view"_s);
    app.setApplicationVersion(u"1.0.0"_s);
    app.setDesktopFileName(u"io.github.codingerr0r.r9view"_s);
    QIcon::setThemeName(QIcon::themeName());
    app.setWindowIcon(QIcon::fromTheme(u"io.github.codingerr0r.r9view"_s,
                                       QIcon(u":/qt/qml/R9View/icons/r9view.svg"_s)));

    // Pin the control style: the desktop's Qt theme has no say over a viewer
    // that is drawn edge to edge in its own palette.
    QQuickStyle::setStyle(u"Basic"_s);

    QCommandLineParser parser;
    parser.setApplicationDescription(
        u"r9view -- a touch-first image and comic viewer.\n"
        "Opens a folder of images, a single image, or a zip/cbz/rar/cbr/7z archive."_s);
    parser.addHelpOption();
    parser.addVersionOption();
    parser.addPositionalArgument(u"target"_s, u"Folder, image, or comic archive to open."_s);
    QCommandLineOption listOption(u"list"_s, u"Print the page order that would be read, then exit."_s);
    parser.addOption(listOption);
    parser.process(app);

    // --list is how you check that a weirdly named archive really does come out
    // in the right order, without opening a window.
    if (parser.isSet(listOption)) {
        const QStringList targets = parser.positionalArguments();
        if (targets.isEmpty()) {
            qWarning("--list needs a folder or archive");
            return 2;
        }
        int start = 0;
        QString error;
        const auto source = PageSource::open(targets.first(), &start, &error);
        if (!source) {
            qWarning("%s: %s", qPrintable(targets.first()), qPrintable(error));
            return 1;
        }
        QTextStream out(stdout);
        for (int i = 0; i < source->count(); ++i)
            out << (i + 1) << "\t" << source->entries().at(i).name << "\n";
        return 0;
    }

    QQmlApplicationEngine engine;

    // Ask the engine for the Book singleton rather than making one here and
    // hoping QML adopts it. It will not: QML constructs its own, and you end up
    // with C++ opening a file on an object the interface never looks at.
    Book *book = engine.singletonInstance<Book *>(u"R9View"_s, u"Book"_s);
    if (!book) {
        qWarning("could not create the Book singleton");
        return 1;
    }

    engine.addImageProvider(u"page"_s, new PageProvider(book->store(), false));
    engine.addImageProvider(u"thumb"_s, new PageProvider(book->store(), true));

    engine.loadFromModule(u"R9View"_s, u"Main"_s);
    if (engine.rootObjects().isEmpty())
        return 1;

    const QStringList args = parser.positionalArguments();
    if (!args.isEmpty())
        book->openPath(args.first());

    return app.exec();
}
