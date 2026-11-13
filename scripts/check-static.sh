#!/bin/bash
# scripts/check-static.sh [--quick | --selftest | --allowlist]
#
# The static checks of design section 12, written from the design alone. One line per rule:
#   STATIC <rule> PASS|FAIL|PENDING|WARN     (what broke or what is missing follows on indented lines)
# PENDING: the rule's file does not exist yet. --quick exits 0 with PENDING rules; a full run
# (no argument, the one scripts/verify.sh uses) exits 1 on any PENDING or FAIL.
# WARN: a rule that is report-only for now (sqlite-app-open, see $SQLITE_APP_OPEN_IS_FAIL); it never changes the
# exit code. Set that variable to 1 once the app's second SQLite connection is gone and the rule then FAILs.
# --selftest: plants violations in a throwaway copy under $TMPDIR and prints SELFTEST <plant> RED.
# --allowlist: prints the allowlist (one "<rule> <module>" line each), for kit-privacy.sh to compare
#   with scripts/kit-lib/static-allowlist.txt.
# 17 rules. The 17th, log-typed (plan 3), is PENDING until a source file declares Log, then PASS or FAIL.
# Exit codes: 0 pass; 1 a rule failed, or a rule is PENDING in a full run; 2 usage.
# Source rules read Sources/**/*.swift with comments removed (strings kept). It runs perl, which
# ships with macOS, because the rules need a real tokenizer for comments and strings.
exec /usr/bin/perl -x -- "$0" "$@"
#!perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Find;
use File::Path qw(make_path remove_tree);
use File::Temp qw(tempdir);

my $ME   = abs_path($0);
my $ROOT = dirname(dirname($ME));

# ---------------------------------------------------------------------------------------------
# The allowlist: design section 12, one module per rule. A new entry is a design change.
# A module is a file name without .swift, or a folder name, inside Sources.
# ---------------------------------------------------------------------------------------------
my @ALLOW = (
    [ 'file-open-parse', 'FileGate' ],
    [ 'file-open-parse', 'IndexReader' ],
    [ 'file-open-parse', 'ModelFiles' ],
    [ 'file-open-parse', 'PreviewReader' ],
    [ 'file-open-parse', 'Probe' ],
    [ 'file-open-parse', 'Readers' ],
    [ 'file-open-parse', 'ScratchPNG' ],
    [ 'file-open-parse', 'SettingsFile' ],
    [ 'sqlite-write',    'IndexStore' ],
    [ 'url-session',     'ModelDownload' ],
    # Probe is exempt from the write-OPEN patterns only (its one append-open is judged by the probe guard below);
    # it is NOT exempt from delete, unlink, rename or truncate (round C, F16a).
    [ 'write-open',      'Probe' ],
    [ 'write-delete',    'Scratch' ],
    [ 'write-delete',    'ScratchPNG' ],
    [ 'write-delete',    'SesameFolder' ],
    # Process and network APIs: these exact files only (a path, not a module name). FolderPicker runs the one
    # `defaults delete` subprocess; HelperClient starts the helper (the app's own design; round C, F16c).
    [ 'process-network', 'Sources/Sesame/Setup/FolderPicker.swift' ],
    [ 'process-network', 'Sources/Sesame/HelperClient.swift' ],
    # Plan 3 (design change, accepted by the controller: Decisions D9 and D13). GitFiles is the one place `git` is started
    # (a path, not a module name). `Log` is the one module that writes app.log, index.log and encode.log (rule log-typed).
    [ 'process-network', 'Sources/SesameEngine/GitFiles.swift' ],
    [ 'log-write',       'Log' ],
    [ 'literal-colours', 'Sources/Sesame/UI/Design.swift' ],
);

# Round C, F16b. The design allows the app target one SQLite read connection, through IndexReader (SesameEngine).
# The app target now opens SQLite only through IndexReader, so the rule `sqlite-app-open` is a FAIL, not a WARN.
# The selftest plant expects FAIL by itself.
my $SQLITE_APP_OPEN_IS_FAIL = 1;

# Launch settings (design section 14, plan 1 rules): name => the files that may read it.
my %SETTING_FILES = (
    SESAME_MODEL_HOST    => ['Sources/Sesame/ModelDownload.swift'],
    SESAME_PROBE_FILE    => ['Sources/Sesame/Probe.swift'],
    SESAME_FAKE_EMBEDDER => [ 'Sources/SesameHelper/main.swift', 'Sources/SesameEngine/Embedder.swift' ],
);

# Design section 1 and 4: the never-read key and password names, written once, in the Rules table.
my @KEY_NAMES = ( '.pem', '.key', '.p12', '.pfx', 'id_rsa', '.env', '.kdbx', 'id_dsa', 'id_ecdsa', 'id_ed25519' );

my $ENT_ONLY = 'com.apple.security.automation.apple-events';

my @RULE_ORDER = qw(
  plist-lint no-camera-mic entitlements url-session file-open-parse write-delete sqlite-write
  sqlite-app-open process-network app-imports user-defaults schema-columns anchor-keynames anchor-filegate
  fake-embedder-readers test-only-launch-settings log-typed literal-colours
);

# ---------------------------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------------------------
sub shq { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'"; }

sub slurp {
    my $p = shift;
    open( my $fh, '<', $p ) or return undef;
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

# Comments become spaces (newlines kept, so line numbers hold); string literals are kept whole.
sub strip_comments {
    my $t = shift;
    $t =~ s{
        (   \#+"""(?:.*?)"""\#+
          | """ (?: \\. | [^\\] )*? """
          | \#+" (?: [^"\n] | "(?!\#) )* "\#+
          | " (?: \\. | [^"\\\n] )* "
          | // [^\n]*
          | /\* (?: [^*] | \*(?!/) )* \*/
        )
    }{
        my $m = $1;
        ( $m =~ m{^//} || $m =~ m{^/\*} ) ? ( $m =~ s/[^\n]/ /gr ) : $m
    }gsxe;
    return $t;
}

# rel path => comment-stripped code, for every .swift file under Sources.
sub load_sources {
    my $root = shift;
    my %src;
    my $dir = "$root/Sources";
    return \%src unless -d $dir;
    find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $_ && /\.swift$/;
                my $rel = substr( $File::Find::name, length($root) + 1 );
                my $raw = slurp($File::Find::name);
                $src{$rel} = strip_comments( defined $raw ? $raw : '' );
            },
        },
        $dir
    );
    return \%src;
}

# [line, matched text, line text] for every match of $re.
sub hits {
    my ( $code, $re ) = @_;
    my @h;
    while ( $code =~ /$re/g ) {
        my $pos  = $-[0];
        my $text = $&;
        my $line = 1 + ( substr( $code, 0, $pos ) =~ tr/\n// );
        my $ls   = rindex( $code, "\n", $pos - 1 ) + 1;
        my $le   = index( $code, "\n", $pos );
        $le = length($code) if $le < 0;
        my $lt = substr( $code, $ls, $le - $ls );
        $lt =~ s/^\s+|\s+$//g;
        $lt = substr( $lt, 0, 100 );
        push @h, [ $line, $text, $lt ];
    }
    return @h;
}

sub modules_for {
    my $rule = shift;
    return [ map { $_->[1] } grep { $_->[0] eq $rule } @ALLOW ];
}

sub module_ok {
    my ( $rel, $mods ) = @_;
    my ($stem) = $rel =~ m{([^/]+)\.swift$};
    my @dirs = split m{/}, $rel;
    pop @dirs;
    for my $m (@$mods) {
        return 1 if defined $stem && $stem eq $m;
        return 1 if grep { $_ eq $m } @dirs;
    }
    return 0;
}

sub run_cmd {
    my $cmd = join ' ', map { shq($_) } @_;
    my $out = qx($cmd 2>&1);
    return ( $? >> 8, $out );
}

sub paths_of_plists {
    my $root = shift;
    my @p;
    push @p, "$root/Resources/Info.plist" if -f "$root/Resources/Info.plist";
    push @p, "$root/dist/Sesame.app/Contents/Info.plist" if -f "$root/dist/Sesame.app/Contents/Info.plist";
    return @p;
}

sub entitlement_keys_of_text {
    my $t = shift;
    my %k;
    $k{$1} = 1 while $t =~ m{<key>([^<]+)</key>}g;
    return sort keys %k;
}

# ---------------------------------------------------------------------------------------------
# rules: each takes ($root, \%src) and returns (STATUS, [detail lines])
# ---------------------------------------------------------------------------------------------
my %RULE;

$RULE{'plist-lint'} = sub {
    my ($root) = @_;
    my @p = paths_of_plists($root);
    return ( 'PENDING', ['Resources/Info.plist does not exist yet'] ) unless -f "$root/Resources/Info.plist";
    my @bad;
    for my $p (@p) {
        my ( $rc, $out ) = run_cmd( 'plutil', '-lint', $p );
        if ( $rc != 0 ) { $out =~ s/\s+$//; push @bad, "plutil -lint failed: $out"; }
    }
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

$RULE{'no-camera-mic'} = sub {
    my ($root) = @_;
    return ( 'PENDING', ['Resources/Info.plist does not exist yet'] ) unless -f "$root/Resources/Info.plist";
    my @bad;
    my @files = paths_of_plists($root);
    push @files, glob( shq("$root/Resources") . '/*.entitlements' );
    for my $f (@files) {
        my $t = slurp($f);
        next unless defined $t;
        for my $w (qw(NSCameraUsageDescription NSMicrophoneUsageDescription NSAudioCaptureUsageDescription
                      com.apple.security.device.camera com.apple.security.device.audio-input)) {
            push @bad, "$w in " . substr( $f, length($root) + 1 ) if index( $t, $w ) >= 0;
        }
    }
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

$RULE{'entitlements'} = sub {
    my ($root) = @_;
    my @ent = glob( shq("$root/Resources") . '/*.entitlements' );
    my $app = "$root/dist/Sesame.app";
    return ( 'PENDING', ['no Resources/*.entitlements and no dist/Sesame.app yet'] ) unless @ent || -d $app;
    my @bad;
    for my $f (@ent) {
        my @k = entitlement_keys_of_text( slurp($f) // '' );
        my $rel = substr( $f, length($root) + 1 );
        push @bad, "$rel keys: " . ( @k ? join( ', ', @k ) : '(none)' ) . "; only $ENT_ONLY is allowed"
          unless @k == 1 && $k[0] eq $ENT_ONLY;
    }
    if ( -d $app ) {
        my $cmd = 'codesign -d --entitlements :- ' . shq($app) . ' 2>/dev/null';
        my $out = qx($cmd);
        my @k   = entitlement_keys_of_text($out);
        push @bad, "dist/Sesame.app signature keys: " . ( @k ? join( ', ', @k ) : '(none)' ) . "; only $ENT_ONLY is allowed"
          unless @k == 1 && $k[0] eq $ENT_ONLY;
    }
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

$RULE{'url-session'} = sub {
    my ( $root, $src ) = @_;
    my $mods = modules_for('url-session');
    my @bad;
    for my $rel ( sort keys %$src ) {
        my $code = $src->{$rel};
        my @h = hits( $code, qr/\bURLSession/ );
        next unless @h;
        if ( !module_ok( $rel, $mods ) ) {
            push @bad, "$rel:$_->[0]: URLSession outside ModelDownload.swift: $_->[2]" for @h;
            next;
        }
        for my $b ( hits( $code, qr/\bURLSession\.shared\b|\bURLSessionConfiguration\.(?:default|background)\b/ ) ) {
            push @bad, "$rel:$b->[0]: not an ephemeral configuration: $b->[2]";
        }
        push @bad, "$rel: URLSession used but URLSessionConfiguration.ephemeral never appears"
          unless $code =~ /URLSessionConfiguration\s*\.\s*ephemeral\b/;
    }
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

# File-open and file-parse APIs, outside FileGate, the helper's readers and the four app modules.
my @OPEN_PATTERNS = (
    qr/(?<![\w.])open\s*\([^)\n]*\bO_[A-Z_]+/,
    qr/\b(?:Darwin|Glibc)\.open\s*\(/,
    qr/(?<![\w.])fopen\s*\(/,
    qr/\bmmap\s*\(/,
    qr/\bFileHandle\s*\(\s*for(?:Reading|Writing|Updating)/,
    qr/\bN?S?Data\s*\(\s*contentsOf(?:File)?\s*:/,
    qr/\bNSImage\s*\(\s*(?:contentsOf|contentsOfFile|byReferencing)/,
    qr/\b(?:NS)?String\s*\(\s*contentsOf(?:File)?\s*:/,
    qr/\bInputStream\s*\(\s*(?:url|fileAtPath)/,
    qr/\.contents\s*\(\s*atPath/,
    qr/\bCGImageSourceCreateWithURL\b/,
    qr/\bPDFDocument\s*\(\s*url\s*:/,
    qr/\bAVURLAsset\b|\bAVAsset\s*\(\s*url|\bAVAudioFile\s*\(/,
    qr/\bSFSpeechURLRecognitionRequest\b/,
    qr/\bVNImageRequestHandler\s*\(\s*url/,
    qr/\bNSAttributedString\s*\(\s*(?:url|fileURL)/,
);

$RULE{'file-open-parse'} = sub {
    my ( $root, $src ) = @_;
    my $mods = modules_for('file-open-parse');
    my @bad;
    for my $rel ( sort keys %$src ) {
        next if module_ok( $rel, $mods );
        for my $re (@OPEN_PATTERNS) {
            push @bad, "$rel:$_->[0]: file-open or file-parse API outside the allowlist: $_->[2]"
              for hits( $src->{$rel}, $re );
        }
    }
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

# Delete, unlink, rename and truncate: only SesameFolder, Scratch and ScratchPNG may call these. Nothing else is
# exempt, Probe included (round C, F16a).
my @DELETE_PATTERNS = (
    qr/\.(?:removeItem|trashItem|moveItem|replaceItem(?:At)?)\s*\(/,
    qr/(?<![\w.])(?<!func )(?:unlink|unlinkat|rmdir|rename|renameat|renamex_np|removefile|truncate|ftruncate)\s*\(/,
);

# The other write APIs: creating, opening for write, changing attributes. Probe's one append-open is exempt from
# these (module `write-open`) because the probe guard judges it; every other file outside the delete modules fails.
my @WRITE_PATTERNS = (
    qr/\.(?:copyItem|linkItem|createDirectory|createFile|createSymbolicLink|setAttributes)\s*\(/,
    qr/\.write\s*\(\s*(?:to|toFile)\s*:/,
    qr/\bFileHandle\s*\(\s*(?:forWriting|forUpdating)/,
    qr/\bOutputStream\s*\(\s*(?:url|toFileAtPath)/,
    qr/\bO_(?:WRONLY|RDWR|CREAT|APPEND|TRUNC)\b/,
    qr/(?<![\w.])(?<!func )(?:mkdir|mkdirat|mkstemp|mkdtemp|chmod|fchmod|chown|fchown|utimes|futimes|lutimes|futimens|utimensat|setxattr|fsetxattr|removexattr|fremovexattr|setattrlist|symlink|link|clonefile|copyfile|fcopyfile)\s*\(/,
    qr/(?<![\w.])fopen\s*\([^)\n]*"[wa+]/,
);

$RULE{'write-delete'} = sub {
    my ( $root, $src ) = @_;
    my $mods  = modules_for('write-delete');
    my $opens = modules_for('write-open');
    my @bad;
    for my $rel ( sort keys %$src ) {
        next if module_ok( $rel, $mods );
        for my $re (@DELETE_PATTERNS) {
            push @bad, "$rel:$_->[0]: delete, unlink, rename or truncate API outside SesameFolder, Scratch and ScratchPNG (no other module is exempt): $_->[2]"
              for hits( $src->{$rel}, $re );
        }
        next if module_ok( $rel, $opens );
        for my $re (@WRITE_PATTERNS) {
            push @bad, "$rel:$_->[0]: write API outside SesameFolder, Scratch and ScratchPNG: $_->[2]"
              for hits( $src->{$rel}, $re );
        }
    }
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

$RULE{'sqlite-write'} = sub {
    my ( $root, $src ) = @_;
    my $mods = modules_for('sqlite-write');
    my @bad;
    for my $rel ( sort keys %$src ) {
        next if module_ok( $rel, $mods );
        my $code = $src->{$rel};
        for my $re ( qr/\bsqlite3_open(?:16)?\s*\(/, qr/\bSQLITE_OPEN_(?:READWRITE|CREATE)\b/ ) {
            push @bad, "$rel:$_->[0]: SQLite opened for writing outside IndexStore: $_->[2]" for hits( $code, $re );
        }
        if ( $code =~ /\bsqlite3_open_v2\b/ && $code !~ /\bSQLITE_OPEN_READONLY\b/ ) {
            push @bad, "$rel: sqlite3_open_v2 without SQLITE_OPEN_READONLY outside IndexStore";
        }
    }
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

# The app target (Sources/Sesame/) opens SQLite only through IndexReader, which lives in SesameEngine: any sqlite3_open*
# call under Sources/Sesame/ is a second connection. WARN-only until $SQLITE_APP_OPEN_IS_FAIL is set (see the top).
$RULE{'sqlite-app-open'} = sub {
    my ( $root, $src ) = @_;
    my @bad;
    for my $rel ( sort keys %$src ) {
        next unless $rel =~ m{^Sources/Sesame/};
        push @bad, "$rel:$_->[0]: the app target opens SQLite itself (only IndexReader may): $_->[2]"
          for hits( $src->{$rel}, qr/\bsqlite3_open\w*\s*\(/ );
    }
    return ( 'PASS', [] ) unless @bad;
    return ( $SQLITE_APP_OPEN_IS_FAIL ? 'FAIL' : 'WARN', \@bad );
};

# Subprocess and raw-network APIs anywhere in product code (the app, the helper and the engine both link): only the
# exact files in the `process-network` allowlist may use them. Matching is by exact relative path, so a file of the
# same name in another folder is not exempt. The helper target has no entry and none is expected.
my @PROCESS_NETWORK_PATTERNS = (
    qr/(?<!\w)Process\s*\(/,
    qr/\bProcess\s*\.\s*(?:run|launchedProcess)\s*\(/,
    qr/\bNSTask\b/,
    qr/\bposix_spawn\w*\s*\(/,
    qr/(?<!\w)(?<!func )socket\s*\(/,
    qr/\bNWConnection\b/,
    qr/\bNSURLConnection\b/,
);

$RULE{'process-network'} = sub {
    my ( $root, $src ) = @_;
    my %exact = map { $_ => 1 } @{ modules_for('process-network') };
    my @bad;
    for my $rel ( sort keys %$src ) {
        next if $exact{$rel};
        for my $re (@PROCESS_NETWORK_PATTERNS) {
            push @bad, "$rel:$_->[0]: $_->[1] outside the process-network allowlist: $_->[2]" for hits( $src->{$rel}, $re );
        }
    }
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

$RULE{'app-imports'} = sub {
    my ( $root, $src ) = @_;
    my @bad;
    for my $rel ( sort keys %$src ) {
        next unless $rel =~ m{^Sources/Sesame/};
        push @bad, "$rel:$_->[0]: the app target imports $_->[1]"
          for hits( $src->{$rel}, qr/^[ \t]*(?:\@\w+\s+)?import\s+(?:\w+\s+)?(?:ImageIO|PDFKit|Vision|Speech)\b/m );
    }
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

$RULE{'user-defaults'} = sub {
    my ( $root, $src ) = @_;
    my @bad;
    for my $rel ( sort keys %$src ) {
        push @bad, "$rel:$_->[0]: $_->[1] is not allowed: $_->[2]"
          for hits( $src->{$rel}, qr/\bUserDefaults\b|\bNSUserDefaults(?:Controller)?\b|\@AppStorage\b|\bsetFrameAutosaveName\b|\bautosaveName\b|\bsetFrameUsingName\b/ );
    }
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

# Words that make a column a query, open or count column. page_count (a page's own length) is allowed.
my %FORBIDDEN_WORD = map { $_ => 1 } qw(query queries open opens opened opening count counts history);

sub column_words {
    my $n = shift;
    $n =~ s/([a-z0-9])([A-Z])/$1_$2/g;
    return map { lc } grep { length } split /[^A-Za-z0-9]+/, $n;
}

sub columns_of_body {
    my $body = shift;
    my @cols;
    my ( $depth, $cur ) = ( 0, '' );
    my @pieces;
    for my $ch ( split //, $body ) {
        if    ( $ch eq '(' ) { $depth++; $cur .= $ch; }
        elsif ( $ch eq ')' ) { $depth--; $cur .= $ch; }
        elsif ( $ch eq ',' && $depth == 0 ) { push @pieces, $cur; $cur = ''; }
        else { $cur .= $ch; }
    }
    push @pieces, $cur if $cur =~ /\S/;
    for my $p (@pieces) {
        $p =~ s/^\s+//;
        next if $p =~ /^(?:PRIMARY|UNIQUE|FOREIGN|CHECK|CONSTRAINT)\b/i;
        my ($name) = $p =~ /^["`\[]?([A-Za-z_][A-Za-z0-9_]*)["`\]]?/;
        next unless defined $name;
        next if $p =~ /^\S+\s*=/;                    # fts5 option such as tokenize = '...'
        next if $name =~ /^(?:tokenize|content|content_rowid|prefix|columnsize|detail)$/i && $p =~ /=/;
        push @cols, $name;
    }
    return @cols;
}

$RULE{'schema-columns'} = sub {
    my ( $root, $src ) = @_;
    my @bad;
    for my $rel ( sort keys %$src ) {
        my $code = $src->{$rel};
        while ( $code =~ /CREATE\s+(?:VIRTUAL\s+)?TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?["`\[]?([\w.]+)["`\]]?\s*(?:USING\s+\w+\s*)?\(/gi ) {
            my $table = $1;
            my $start = pos($code);
            my ( $depth, $i ) = ( 1, $start );
            while ( $i < length($code) && $depth > 0 ) {
                my $c = substr( $code, $i, 1 );
                $depth++ if $c eq '(';
                $depth-- if $c eq ')';
                $i++;
            }
            my $body = substr( $code, $start, $i - $start - 1 );
            for my $col ( columns_of_body($body) ) {
                next if lc($col) eq 'page_count';
                my @w = grep { $FORBIDDEN_WORD{$_} } column_words($col);
                push @bad, "$rel: table $table has column $col (a query, open or count column is not allowed)" if @w;
            }
        }
        while ( $code =~ /ALTER\s+TABLE\s+[\w.]+\s+ADD\s+(?:COLUMN\s+)?["`\[]?([A-Za-z_]\w*)/gi ) {
            my $col = $1;
            next if lc($col) eq 'page_count';
            push @bad, "$rel: ALTER TABLE adds column $col (a query, open or count column is not allowed)"
              if grep { $FORBIDDEN_WORD{$_} } column_words($col);
        }
    }
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

sub string_literals {
    my $code = shift;
    my @s;
    while ( $code =~ /"((?:\\.|[^"\\\n])*)"/g ) {
        my $pos = $-[0];
        push @s, [ 1 + ( substr( $code, 0, $pos ) =~ tr/\n// ), $1 ];
    }
    return @s;
}

sub key_regex {
    my $n = shift;
    my $q = quotemeta($n);
    return $n =~ /^\./
      ? qr/(?<![A-Za-z0-9_])$q(?![A-Za-z0-9_])/
      : qr/(?<![A-Za-z0-9_.])$q(?![A-Za-z0-9_])/;
}

$RULE{'anchor-keynames'} = sub {
    my ( $root, $src ) = @_;
    my @decl = grep { $src->{$_} =~ /\b(?:enum|struct|class|actor)\s+Rules\b/ } sort keys %$src;
    return ( 'PENDING', ['no source file declares Rules yet'] ) unless @decl;
    return ( 'FAIL', [ 'Rules is declared in more than one file: ' . join( ', ', @decl ) ] ) if @decl > 1;
    my $table = $decl[0];
    my @bad;
    for my $name (@KEY_NAMES) {
        my $re = key_regex($name);
        my %where;
        my $total = 0;
        for my $rel ( sort keys %$src ) {
            for my $lit ( string_literals( $src->{$rel} ) ) {
                my $n = () = $lit->[1] =~ /$re/g;
                next unless $n;
                $total += $n;
                $where{"$rel:$lit->[0]"} = 1;
            }
        }
        my $where = join( ', ', sort keys %where );
        if ( $total == 0 ) {
            push @bad, "key name $name appears in no string literal (it must appear once, in the Rules table in $table)";
        }
        elsif ( $total != 1 ) {
            push @bad, "key name $name appears $total times, not once: $where";
        }
        elsif ( $where !~ /^\Q$table\E:/ ) {
            push @bad, "key name $name is outside the Rules table ($table): $where";
        }
    }
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

$RULE{'anchor-filegate'} = sub {
    my ( $root, $src ) = @_;
    my $exact = qr/O_RDONLY \| O_NOFOLLOW/;
    my $loose = qr/O_RDONLY\s*\|\s*O_NOFOLLOW|O_NOFOLLOW\s*\|\s*O_RDONLY/;
    my @decl  = grep { $src->{$_} =~ /\b(?:enum|struct|class|actor)\s+FileGate\b/ } sort keys %$src;
    my %flag  = map { $_ => [ hits( $src->{$_}, $loose ) ] } grep { $src->{$_} =~ $loose } keys %$src;
    my @bad;
    if ( !@decl ) {
        if (%flag) {
            push @bad, "$_:$flag{$_}[0][0]: O_RDONLY | O_NOFOLLOW appears but FileGate is declared nowhere" for sort keys %flag;
            return ( 'FAIL', \@bad );
        }
        return ( 'PENDING', ['no source file declares FileGate yet'] );
    }
    return ( 'FAIL', [ 'FileGate is declared in more than one file: ' . join( ', ', @decl ) ] ) if @decl > 1;
    my $gate = $decl[0];
    my $n    = scalar @{ $flag{$gate} || [] };
    my $e    = () = $src->{$gate} =~ /$exact/g;
    push @bad, "$gate holds O_RDONLY | O_NOFOLLOW $n times, not once" if $n != 1;
    push @bad, "$gate does not spell the flags exactly as O_RDONLY | O_NOFOLLOW" if $n == 1 && $e != 1;
    for my $f ( sort grep { $_ ne $gate } keys %flag ) {
        push @bad, "$f:$flag{$f}[0][0]: O_RDONLY | O_NOFOLLOW outside the file that declares FileGate ($gate)";
    }
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

$RULE{'fake-embedder-readers'} = sub {
    my ( $root, $src ) = @_;
    my $name    = 'SESAME_FAKE_EMBEDDER';
    my @allowed = sort @{ $SETTING_FILES{$name} };
    my %allowed = map { $_ => 1 } @allowed;
    my @bad;
    my @readers = grep { $src->{$_} =~ /\b$name\b/ } sort keys %$src;
    for my $rel ( grep { !$allowed{$_} } @readers ) {
        push @bad, "$rel:$_->[0]: $name outside the two reader files: $_->[2]" for hits( $src->{$rel}, qr/\b$name\b/ );
    }
    my @own = grep { $allowed{$_} } @readers;
    for my $rel (@own) {
        my $code = $src->{$rel};
        while ( $code =~ /"\Q$name\E"/g ) {
            my $end  = pos($code);
            my $line = 1 + ( substr( $code, 0, $end ) =~ tr/\n// );
            my $rest = substr( $code, $end, 400 );
            my ($same) = $rest =~ /^([^\n]*)/;
            my ($next) = $rest =~ /^[^\n]*\n([^\n]*)/;
            $next = '' unless defined $next;
            push @bad, "$rel:$line: $name is read with a fallback value"
              if $same =~ /\?\?|\bdefault\s*:/ || $next =~ /^\s*(?:\?\?|\bdefault\s*:)/;
        }
    }
    return ( 'FAIL', \@bad ) if @bad;
    return ( 'PENDING', [ 'neither ' . join( ' nor ', @allowed ) . " reads $name yet" ] ) unless @own;
    my %own = map { $_ => 1 } @own;
    push @bad, "$_ does not read $name (only " . join( ', ', @own ) . " does)" for grep { !$own{$_} } @allowed;
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

# Probe guard (design section 9.2 and 12): Probe may open for appending only the file named by
# SESAME_PROBE_FILE. So Probe.swift holds exactly one file-open call, and the path that call takes
# comes, through its let/var/guard-let bindings, only from a read of SESAME_PROBE_FILE. (A Probe
# with no open call at all is fine: it then writes nothing.)
my $PROBE_FILE = 'Sources/Sesame/Probe.swift';
my $PROBE_VAR  = 'SESAME_PROBE_FILE';

my @PROBE_OPENERS = (
    qr/(?<!func )(?<![\w.])open\s*\(/,
    qr/(?<![\w.])openat\s*\(/,
    qr/\b(?:Darwin|Glibc)\.open\s*\(/,
    qr/(?<![\w.])fopen\s*\(/,
    qr/\bmmap\s*\(/,
    qr/\bFileHandle\s*\(\s*for\w+/,
    qr/\bOutputStream\s*\(/,
    qr/\.write\s*\(\s*(?:to|toFile)\s*:/,
    qr/\.createFile\s*\(/,
    qr/\bN?S?Data\s*\(\s*contentsOf/,
);

# [start, end) of the first argument of the call whose "(" is at $open.
sub call_arg {
    my ( $code, $open ) = @_;
    my ( $depth, $n ) = ( 0, length $code );
    for ( my $i = $open ; $i < $n ; $i++ ) {
        my $c = substr( $code, $i, 1 );
        if ( $c eq '"' ) {
            $i++;
            while ( $i < $n ) {
                my $d = substr( $code, $i, 1 );
                if ( $d eq '\\' ) { $i += 2; next; }
                last if $d eq '"';
                $i++;
            }
            next;
        }
        if    ( $c =~ /[(\[{]/ ) { $depth++; }
        elsif ( $c =~ /[)\]}]/ ) { $depth--; return ( $open + 1, $i ) if $depth == 0; }
        elsif ( $c eq ',' && $depth == 1 ) { return ( $open + 1, $i ); }
    }
    return ( $open + 1, $n );
}

sub probe_openers {
    my $code = shift;
    my @o;
    for my $re (@PROBE_OPENERS) {
        pos($code) = 0;
        while ( $code =~ /$re/g ) {
            my $m = $-[0];
            my $p = index( $code, '(', $m );
            next if $p < 0;
            my ( $s, $e ) = call_arg( $code, $p );
            push @o, { pos => $m, line => 1 + ( substr( $code, 0, $m ) =~ tr/\n// ), s => $s, e => $e };
        }
    }
    return sort { $a->{pos} <=> $b->{pos} } @o;
}

# Free lowercase identifiers of an expression (member names, labels, calls and string text left out).
sub free_idents {
    my $e = shift;
    $e =~ s/"(?:\\.|[^"\\\n])*"/""/g;
    $e =~ s/\bself\.//g;
    my @id;
    while ( $e =~ /(?<![\w.\$])([a-z_]\w*)\b(?!\s*[(:])/g ) {
        my $w = $1;
        push @id, $w unless $w =~ /^(?:nil|true|false|self|try|as|is|in)$/;
    }
    return @id;
}

# Does every binding of identifier $x in $code come from a read of SESAME_PROBE_FILE?
sub probe_bound {
    my ( $code, $x, $depth, $why ) = @_;
    if ( $depth > 4 ) { push @$why, "$x: binding chain too deep"; return 0; }
    my $qx = quotemeta($x);
    my @expr;
    while ( $code =~ /\b(?:let|var)\s+$qx\b(?:\s*:\s*[^=\n]+?)?\s*=(?!=)/g ) { push @expr, [ pos($code), 'binding' ]; }
    while ( $code =~ /(?<![\w.])(?<!let )(?<!var )$qx\s*=(?!=)/g )            { push @expr, [ pos($code), 'assignment' ]; }
    if ( $code =~ /(?:\bfunc\s+\w+\s*\([^)]*?|,\s*)(?:\w+\s+)?$qx\s*:\s*[A-Z]/ ) {
        push @$why, "$x is a function parameter, so its value does not come from $PROBE_VAR";
        return 0;
    }
    if ( !@expr ) { push @$why, "$x is bound nowhere in the file"; return 0; }
    my $ok = 1;
    for my $b (@expr) {
        my $rest = substr( $code, $b->[0], 400 );
        my $stmt = '';
        for my $ln ( split /(?<=\n)/, $rest ) {
            if ( $stmt ne '' && $ln !~ /^\s*(?:[.?:\[)]|&&|\|\|)/ ) { last; }
            $stmt .= $ln;
        }
        $stmt =~ s/\belse\b.*//s;
        next if $stmt =~ /\b$PROBE_VAR\b/;
        my @id = free_idents($stmt);
        if ( !@id ) {
            ( my $t = $stmt ) =~ s/\s+/ /g;
            push @$why, "$x = " . substr( $t, 0, 60 ) . " does not read $PROBE_VAR";
            $ok = 0;
            next;
        }
        for my $y (@id) {
            next if $y eq $x;
            $ok = 0 unless probe_bound( $code, $y, $depth + 1, $why );
        }
    }
    return $ok;
}

sub probe_guard {
    my $code = shift;
    my @bad;
    my @o = probe_openers($code);
    return @bad unless @o;
    if ( @o > 1 ) {
        push @bad, "$PROBE_FILE:$o[1]{line}: holds " . scalar(@o) . " file-open calls, not one (lines "
          . join( ', ', map { $_->{line} } @o ) . ")";
        return @bad;
    }
    my $arg = substr( $code, $o[0]{s}, $o[0]{e} - $o[0]{s} );
    $arg =~ s/^\s*\w+\s*:\s*//;
    return @bad if $arg =~ /\b$PROBE_VAR\b/;
    my @id = free_idents($arg);
    ( my $shown = $arg ) =~ s/\s+/ /g;
    $shown = substr( $shown, 0, 60 );
    if ( !@id ) {
        push @bad, "$PROBE_FILE:$o[0]{line}: the open call's path ($shown) does not come from $PROBE_VAR";
        return @bad;
    }
    for my $x (@id) {
        my @why;
        next if probe_bound( $code, $x, 0, \@why );
        push @why, "$x is not bound to $PROBE_VAR" unless @why;
        push @bad, "$PROBE_FILE:$o[0]{line}: the open call's path ($shown) does not come only from $PROBE_VAR: $_" for @why;
    }
    return @bad;
}

$RULE{'test-only-launch-settings'} = sub {
    my ( $root, $src ) = @_;
    my @bad;
    push @bad, probe_guard( $src->{$PROBE_FILE} ) if exists $src->{$PROBE_FILE};
    for my $rel ( sort keys %$src ) {
        my $code = $src->{$rel};
        for my $h ( hits( $code, qr/\bSESAME_[A-Z0-9_]+/ ) ) {
            my $name = $h->[1];
            my $files = $SETTING_FILES{$name};
            if ( !$files ) {
                push @bad, "$rel:$h->[0]: unknown test-only setting $name";
                next;
            }
            if ( !grep { $_ eq $rel } @$files ) {
                push @bad, "$rel:$h->[0]: $name is read outside " . join( ' and ', @$files ) . ": $h->[2]";
            }
        }
        next unless grep { my $f = $_; grep { $_ eq $rel } @$f } values %SETTING_FILES;
        while ( $code =~ /"(SESAME_[A-Z0-9_]+)"/g ) {
            my $name = $1;
            my $end  = pos($code);
            my $line = 1 + ( substr( $code, 0, $end ) =~ tr/\n// );
            my $rest = substr( $code, $end, 400 );
            my ($same) = $rest =~ /^([^\n]*)/;
            my ($next) = $rest =~ /^[^\n]*\n([^\n]*)/;
            $next = '' unless defined $next;
            if ( $same =~ /\?\?|\bdefault\s*:/ || $next =~ /^\s*(?:\?\?|\bdefault\s*:)/ ) {
                push @bad, "$rel:$line: $name is read with a fallback value";
            }
        }
    }
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

# Plan 3 (design section 12, scenario S8.9): the three logs are written only by the module `Log` (allowlist `log-write`),
# whose events are typed, so a query or a path cannot reach a log. A call that appends or writes whose arguments hold a log
# name as a string literal fails outside Log, and so does one whose arguments use a constant of the same file that holds a
# log name (SesameFolder.append(... to: ...) is such a call). Reading a log, a comment and another file name are not
# touched. PENDING until some file declares Log, as the anchor rules are.
my $LOG_NAME    = qr/(?<![A-Za-z0-9_])(?:app|index|encode)\.log(?![A-Za-z0-9_])/;
my $LOG_LITERAL = qr/"[^"\n]*$LOG_NAME[^"\n]*"/;
my @LOG_WRITE_CALLS = (
    qr/\b(?:append|write|createFile|fputs|fopen|open|FileHandle|OutputStream)\s*\(/,
);

# The text between the "(" at $open and its matching ")", strings skipped.
sub call_text {
    my ( $code, $open ) = @_;
    my ( $depth, $n ) = ( 0, length $code );
    for ( my $i = $open ; $i < $n ; $i++ ) {
        my $c = substr( $code, $i, 1 );
        if ( $c eq '"' ) {
            $i++;
            while ( $i < $n ) {
                my $d = substr( $code, $i, 1 );
                if ( $d eq '\\' ) { $i += 2; next; }
                last if $d eq '"';
                $i++;
            }
            next;
        }
        if    ( $c =~ /[(\[{]/ ) { $depth++; }
        elsif ( $c =~ /[)\]}]/ ) { $depth--; return substr( $code, $open + 1, $i - $open - 1 ) if $depth == 0; }
    }
    return substr( $code, $open + 1 );
}

$RULE{'log-typed'} = sub {
    my ( $root, $src ) = @_;
    my $mods = modules_for('log-write');
    my @decl = grep { $src->{$_} =~ /\b(?:enum|struct|class|actor)\s+Log\b/ } sort keys %$src;
    return ( 'PENDING', ['no source file declares Log yet'] ) unless @decl;
    my @bad;
    for my $rel ( sort keys %$src ) {
        next if module_ok( $rel, $mods );
        my $code = $src->{$rel};
        # names bound to a log-name literal in this file (a constant, an enum raw value)
        my @named = $code =~ /\b(?:let|var|case)\s+(\w+)\b[^=\n]*=\s*$LOG_LITERAL/g;
        for my $re (@LOG_WRITE_CALLS) {
            pos($code) = 0;
            while ( $code =~ /$re/g ) {
                my ( $at, $end ) = ( $-[0], $+[0] );
                my $args = call_text( $code, $end - 1 );
                next unless $args =~ $LOG_LITERAL || grep { $args =~ /(?<![\w.])\Q$_\E\b/ } @named;
                my $line = 1 + ( substr( $code, 0, $at ) =~ tr/\n// );
                push @bad, "$rel:$line: a write to a log file outside the module Log";
            }
        }
    }
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

sub blank_strings {
    my $t = shift;
    $t =~ s{("""(?:\\.|[^\\])*?"""|"(?:\\.|[^"\\\n])*")}{ my $m = $1; $m =~ s/[^\n]/ /gr }gse;
    return $t;
}

my @COLOUR_PATTERNS = (
    qr/\bNSColor\s*\(/,
    qr/\bNSColor\s*\.\s*(?:white|black)\b/,
    qr/(?<![\w.])\.(?:white|black)\b/,
);

$RULE{'literal-colours'} = sub {
    my ( $root, $src ) = @_;
    my %exact = map { $_ => 1 } @{ modules_for('literal-colours') };
    my @bad;
    for my $rel ( sort keys %$src ) {
        next unless $rel =~ m{^Sources/Sesame/};
        next if $exact{$rel};
        my $code = blank_strings( $src->{$rel} );
        for my $re (@COLOUR_PATTERNS) {
            push @bad, "$rel:$_->[0]: literal colour outside UI/Design.swift: $_->[2]" for hits( $code, $re );
        }
    }
    return @bad ? ( 'FAIL', \@bad ) : ( 'PASS', [] );
};

# ---------------------------------------------------------------------------------------------
sub run_rules {
    my $root = shift;
    my $src  = load_sources($root);
    my %res;
    for my $r (@RULE_ORDER) {
        my ( $status, $detail ) = $RULE{$r}->( $root, $src );
        my %seen;
        $res{$r} = [ $status, [ grep { !$seen{$_}++ } @$detail ] ];
    }
    return \%res;
}

sub print_rules {
    my $res = shift;
    for my $r (@RULE_ORDER) {
        my ( $status, $detail ) = @{ $res->{$r} };
        print "STATIC $r $status\n";
        print "  $_\n" for @$detail;
    }
}

sub count_status {
    my ( $res, $s ) = @_;
    return scalar grep { $res->{$_}[0] eq $s } @RULE_ORDER;
}

# ---------------------------------------------------------------------------------------------
# --selftest: throwaway copies under $TMPDIR; the project tree is only read.
# ---------------------------------------------------------------------------------------------
sub copy_tree {
    my ( $from, $to ) = @_;
    make_path($to);
    find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $rel = substr( $File::Find::name, length($from) );
                return if $rel eq '';
                my $dst = "$to$rel";
                if    ( -d $File::Find::name ) { make_path($dst); }
                elsif ( -f $File::Find::name ) {
                    open( my $in,  '<', $File::Find::name ) or return;
                    open( my $out, '>', $dst ) or return;
                    binmode $in;
                    binmode $out;
                    local $/;
                    print $out scalar <$in>;
                    close $in;
                    close $out;
                }
            },
        },
        $from
    );
}

sub put_file {
    my ( $root, $rel, $text, $append ) = @_;
    make_path( dirname("$root/$rel") );
    open( my $fh, $append ? '>>' : '>', "$root/$rel" ) or die "cannot write $root/$rel: $!";
    print $fh $text;
    close $fh;
}

# Rewrites the first argument of Probe's file-open call to a literal path (comments keep their length
# in the stripped text, so offsets there are offsets in the raw text). undef when there is no open call.
sub plant_probe_other_path {
    my $raw = shift;
    my @o   = probe_openers( strip_comments($raw) );
    return undef unless @o;
    my $s = $o[0]{s};
    my $e = $o[0]{e};
    return substr( $raw, 0, $s ) . '"/tmp/planted-other-file"' . substr( $raw, $e );
}

sub selftest {
    my $tmp = $ENV{TMPDIR} || '/tmp';
    $tmp =~ s{/+$}{};
    my $work = tempdir( 'check-static-selftest.XXXXXX', DIR => $tmp, CLEANUP => 0 );
    die "selftest folder is not under $tmp\n" unless index( $work, $tmp ) == 0 && $work =~ /check-static-selftest\./;
    my $rc = 0;
    eval {
        copy_tree( "$ROOT/Sources",   "$work/Sources" );
        copy_tree( "$ROOT/Resources", "$work/Resources" );

        # Baseline: if the scaffold has no FileGate yet, the copy gets a stub so the filegate plant can be judged.
        my $res = run_rules($work);
        if ( $res->{'anchor-filegate'}[0] eq 'PENDING' ) {
            put_file( $work, 'Sources/SesameEngine/FileGate.swift',
                "enum FileGate {\n    static let flags = O_RDONLY | O_NOFOLLOW\n}\n" );
        }

        my @plants = (
            {
                name  => 'urlsession',
                rule  => 'url-session',
                files => [ [ 'Sources/SesameEngine/PlantedSession.swift', "import Foundation\nlet planted = URLSession.shared\n", 0 ] ],
            },
            {
                name  => 'second-o_rdonly-o_nofollow',
                rule  => 'anchor-filegate',
                files => [ [ 'Sources/SesameEngine/PlantedOpen.swift', "let plantedFlags = O_RDONLY | O_NOFOLLOW\n", 0 ] ],
            },
            {
                name  => 'model-host-fallback',
                rule  => 'test-only-launch-settings',
                files => [
                    [
                        'Sources/Sesame/ModelDownload.swift',
                        "import Foundation\nlet plantedHost = ProcessInfo.processInfo.environment[\"SESAME_MODEL_HOST\"] ?? \"https://example.invalid\"\n",
                        1
                    ]
                ],
            },
            {
                name  => 'removeitem',
                rule  => 'write-delete',
                files => [
                    [
                        'Sources/SesameEngine/PlantedRemove.swift',
                        "import Foundation\nfunc plantedRemove() {\n    try? FileManager.default.removeItem(atPath: \"/nonexistent\")\n}\n",
                        0
                    ]
                ],
            },
            {
                # Probe may be exempt from the open-style patterns only: a delete in Probe.swift is red.
                name  => 'probe-removeitem',
                rule  => 'write-delete',
                files => [
                    [
                        $PROBE_FILE,
                        "\nfunc plantedProbeRemove() {\n    try? FileManager.default.removeItem(atPath: \"/nonexistent\")\n}\n",
                        1
                    ]
                ],
            },
            {
                name  => 'probe-unlink',
                rule  => 'write-delete',
                files => [ [ $PROBE_FILE, "\nfunc plantedProbeUnlink() {\n    _ = unlink(\"/nonexistent\")\n}\n", 1 ] ],
            },
            {
                name  => 'probe-rename',
                rule  => 'write-delete',
                files => [ [ $PROBE_FILE, "\nfunc plantedProbeRename() {\n    _ = rename(\"/nonexistent-a\", \"/nonexistent-b\")\n}\n", 1 ] ],
            },
            {
                name  => 'removeitem-in-another-app-file',
                rule  => 'write-delete',
                files => [ [ 'Sources/Sesame/PlantedAppRemove.swift', "import Foundation\nfunc plantedAppRemove() {\n    try? FileManager.default.trashItem(at: URL(fileURLWithPath: \"/nonexistent\"), resultingItemURL: nil)\n}\n", 0 ] ],
            },
            {
                # The app target opens SQLite itself. WARN now ($SQLITE_APP_OPEN_IS_FAIL = 0), FAIL once it is 1.
                # The real tree may already hold one such call (the in-flight fix), so the plant is judged by its own line.
                name       => 'app-sqlite-open',
                rule       => 'sqlite-app-open',
                expect     => ( $SQLITE_APP_OPEN_IS_FAIL ? 'FAIL' : 'WARN' ),
                detail_has => ['PlantedAppSqlite.swift'],
                files      => [ [ 'Sources/Sesame/PlantedAppSqlite.swift', "import SQLite3\nfunc plantedAppSqlite() {\n    var handle: OpaquePointer?\n    _ = sqlite3_open_v2(\"/nonexistent\", &handle, SQLITE_OPEN_READONLY, nil)\n}\n", 0 ] ],
            },
            {
                name       => 'app-process-and-network-apis',
                rule       => 'process-network',
                detail_has => [ 'Process(', 'NSTask', 'posix_spawn(', 'socket(', 'NWConnection', 'NSURLConnection' ],
                files      => [
                    [
                        'Sources/Sesame/PlantedSpawn.swift',
                        "import Foundation\nimport Network\nfunc plantedSpawn() {\n    let a = Process()\n    let b = NSTask()\n    var pid: pid_t = 0\n    _ = posix_spawn(&pid, \"/bin/ls\", nil, nil, [], nil)\n    _ = socket(2, 1, 0)\n    let c: NWConnection? = nil\n    let d: NSURLConnection? = nil\n    _ = (a, b, c, d)\n}\n",
                        0
                    ]
                ],
            },
            {
                name       => 'helper-process',
                rule       => 'process-network',
                detail_has => ['SesameHelper/PlantedSpawn.swift'],
                files      => [ [ 'Sources/SesameHelper/PlantedSpawn.swift', "import Foundation\nfunc plantedHelperSpawn() {\n    let p = Process()\n    _ = p\n}\n", 0 ] ],
            },
            {
                # The allowlist is the exact path: the same file name in the helper target is not exempt.
                name       => 'helper-file-named-folderpicker',
                rule       => 'process-network',
                detail_has => ['SesameHelper/FolderPicker.swift'],
                files      => [ [ 'Sources/SesameHelper/FolderPicker.swift', "import Foundation\nfunc plantedNamedSpawn() {\n    let p = Process()\n    _ = p\n}\n", 0 ] ],
            },
            {
                # `git` is started in one file only (a path): Process( in any other file is red, the same call in
                # GitFiles.swift is not (`exempt`: planted alone after the red plant is taken out, and no line may name it).
                name       => 'git-process-elsewhere',
                rule       => 'process-network',
                detail_has => ['Sources/SesameEngine/PlantedGit.swift'],
                files      => [ [ 'Sources/SesameEngine/PlantedGit.swift', "import Foundation\nfunc plantedGit() {\n    let p = Process()\n    _ = p\n}\n", 0 ] ],
                exempt     => [ 'Sources/SesameEngine/GitFiles.swift', "import Foundation\nfunc plantedGit() {\n    let p = Process()\n    _ = p\n}\n" ],
            },
            {
                # prep: a Log.swift makes the rule live (it is PENDING while no file declares Log). Until plan-3-t22 the
                # product's own log writers are still outside Log, so the baseline may already be FAIL (allow_base_fail)
                # and the plant is judged by the line that names its own file. The same append inside Log.swift is not red.
                name            => 'log-append-elsewhere',
                rule            => 'log-typed',
                allow_base_fail => 1,
                detail_has      => ['Sources/SesameEngine/PlantedLogAppend.swift'],
                prep            => [ [ 'Sources/SesameEngine/Log.swift', "enum Log {}\n", 0 ] ],
                files           => [ [ 'Sources/SesameEngine/PlantedLogAppend.swift', "import Foundation\nfunc plantedLogAppend(_ data: Data) {\n    SesameFolder.append(data, to: SesameFolder.logs.appendingPathComponent(\"index.log\"))\n}\n", 0 ] ],
                exempt          => [ 'Sources/SesameEngine/Log.swift', "import Foundation\nenum Log {\n    static func plantedWrite(_ data: Data) {\n        SesameFolder.append(data, to: SesameFolder.logs.appendingPathComponent(\"index.log\"))\n    }\n}\n" ],
            },
            {
                name       => 'literal-colour-elsewhere',
                rule       => 'literal-colours',
                detail_has => ['Sources/Sesame/PlantedColour.swift'],
                files      => [ [ 'Sources/Sesame/PlantedColour.swift', "import AppKit\nlet plantedColour = NSColor.white\n", 0 ] ],
                exempt     => [ 'Sources/Sesame/UI/Design.swift', "import AppKit\nenum Design {\n    static let plantedInk = NSColor.black\n}\n" ],
            },
            {
                name  => 'probe-second-open',
                rule  => 'test-only-launch-settings',
                files => [
                    [
                        $PROBE_FILE,
                        "\nfunc plantedProbeOpen() {\n    let other = \"/tmp/planted-other-file\"\n    let fd2 = open(other, O_WRONLY | O_APPEND | O_CREAT, 0o600)\n    _ = fd2\n}\n",
                        1
                    ]
                ],
            },
            {
                name      => 'probe-other-path',
                rule      => 'test-only-launch-settings',
                transform => [ $PROBE_FILE, \&plant_probe_other_path ],
            },
            {
                # prep: both reader files read the name (the rule is PASS); the plant adds a read in a third file.
                name  => 'fake-embedder-third-reader',
                rule  => 'fake-embedder-readers',
                prep  => [
                    [ 'Sources/SesameHelper/main.swift',    "\nlet preppedHelperRead = ProcessInfo.processInfo.environment[\"SESAME_FAKE_EMBEDDER\"]\n", 1 ],
                    [ 'Sources/SesameEngine/Embedder.swift', "\nlet preppedEngineRead = ProcessInfo.processInfo.environment[\"SESAME_FAKE_EMBEDDER\"]\n", 1 ],
                ],
                files => [ [ 'Sources/SesameEngine/PlantedFakeRead.swift', "import Foundation\nlet plantedFake = ProcessInfo.processInfo.environment[\"SESAME_FAKE_EMBEDDER\"]\n", 0 ] ],
            },
        );

        $res = run_rules($work);
        for my $p (@plants) {
            my %saved;
            my $base_status = $res->{ $p->{rule} }[0];
            my $base_detail = $res->{ $p->{rule} }[1];
            if ( $p->{prep} ) {
                for my $f ( @{ $p->{prep} } ) {
                    my ( $rel, $text, $append ) = @$f;
                    $saved{$rel} = -e "$work/$rel" ? slurp("$work/$rel") : undef unless exists $saved{$rel};
                    put_file( $work, $rel, $text, $append );
                }
                ( $base_status, $base_detail ) = @{ run_rules($work)->{ $p->{rule} } };
            }
            my $want = $p->{expect} || 'FAIL';
            # A report-only rule may already show a hit on the real tree (WARN); its plant is then judged by its own line.
            # allow_base_fail: the rule may already be FAIL on the real tree; the plant is judged by detail_has alone.
            if ( $base_status ne 'PASS'
                && !( $want eq 'WARN' && $base_status eq 'WARN' )
                && !( $p->{allow_base_fail} && $base_status eq 'FAIL' ) ) {
                print "SELFTEST $p->{name} INVALID baseline: STATIC $p->{rule} is $base_status before the plant\n";
                print "  $_\n" for @$base_detail;
                $rc = 1;
                for my $rel ( keys %saved ) {
                    if ( defined $saved{$rel} ) { put_file( $work, $rel, $saved{$rel}, 0 ); }
                    else                        { unlink "$work/$rel"; }
                }
                next;
            }
            if ( $p->{transform} ) {
                my ( $rel, $fn ) = @{ $p->{transform} };
                my $raw = -e "$work/$rel" ? slurp("$work/$rel") : undef;
                my $new = defined $raw ? $fn->($raw) : undef;
                if ( !defined $new ) {
                    print "SELFTEST $p->{name} INVALID: no file-open call in $rel to change\n";
                    $rc = 1;
                    next;
                }
                $saved{$rel} = $raw;
                put_file( $work, $rel, $new, 0 );
            }
            for my $f ( @{ $p->{files} || [] } ) {
                my ( $rel, $text, $append ) = @$f;
                $saved{$rel} = -e "$work/$rel" ? slurp("$work/$rel") : undef;
                put_file( $work, $rel, $text, $append );
            }
            my $after = run_rules($work);
            my ( $status, $detail ) = @{ $after->{ $p->{rule} } };
            my @missing = grep {
                my $needle = $_;
                !grep { index( $_, $needle ) >= 0 } @$detail
            } @{ $p->{detail_has} || [] };
            for my $rel ( keys %saved ) {
                if ( defined $saved{$rel} ) { put_file( $work, $rel, $saved{$rel}, 0 ); }
                else                        { unlink "$work/$rel"; }
            }
            # exempt: the same code in the one file the allowlist names must not be flagged. It is planted alone (the red
            # plant is out): no line of the rule may name that file, and a rule that was PASS stays PASS.
            my $exempt_bad = '';
            if ( $p->{exempt} && $status eq $want && !@missing ) {
                my ( $erel, $etext ) = @{ $p->{exempt} };
                my $esaved = -e "$work/$erel" ? slurp("$work/$erel") : undef;
                put_file( $work, $erel, $etext, 0 );
                my ( $es, $ed ) = @{ run_rules($work)->{ $p->{rule} } };
                if ( defined $esaved ) { put_file( $work, $erel, $esaved, 0 ); }
                else                   { unlink "$work/$erel"; }
                my @named = grep { index( $_, $erel ) >= 0 } @$ed;
                if    (@named)                              { $exempt_bad = "the same code in $erel is flagged: $named[0]"; }
                elsif ( $base_status eq 'PASS' && $es ne 'PASS' ) { $exempt_bad = "the same code in $erel makes STATIC $p->{rule} $es"; }
            }
            if ( $status eq $want && !@missing && $exempt_bad eq '' ) {
                print "SELFTEST $p->{name} RED\n";
                print "  STATIC $p->{rule} $status\n";
                print "    $_\n" for @$detail;
            }
            elsif ( $exempt_bad ne '' ) {
                print "SELFTEST $p->{name} NOT RED: $exempt_bad\n";
                $rc = 1;
            }
            elsif ( $status eq $want ) {
                print "SELFTEST $p->{name} NOT RED: STATIC $p->{rule} is $status but no line names: " . join( ', ', @missing ) . "\n";
                print "    $_\n" for @$detail;
                $rc = 1;
            }
            else {
                print "SELFTEST $p->{name} NOT RED: STATIC $p->{rule} is $status with the plant in place (wanted $want)\n";
                $rc = 1;
            }
        }
        print "SELFTEST OK\n" if $rc == 0;
        1;
    } or do {
        print "SELFTEST ERROR: $@";
        $rc = 1;
    };
    remove_tree($work) if -d $work && index( $work, $tmp ) == 0 && $work =~ /check-static-selftest\./;
    return $rc;
}

# ---------------------------------------------------------------------------------------------
sub usage {
    print STDERR "usage: scripts/check-static.sh [--quick | --selftest | --allowlist]\n";
    exit 2;
}

usage() if @ARGV > 1;
my $mode = @ARGV ? $ARGV[0] : 'full';
usage() unless $mode =~ /^(?:full|--quick|--selftest|--allowlist)$/ && !( @ARGV && $mode eq 'full' );

if ( $mode eq '--allowlist' ) {
    print "$_->[0] $_->[1]\n" for @ALLOW;
    exit 0;
}
if ( $mode eq '--selftest' ) { exit selftest(); }

my $res     = run_rules($ROOT);
print_rules($res);
my $fail    = count_status( $res, 'FAIL' );
my $pending = count_status( $res, 'PENDING' );
my $pass    = count_status( $res, 'PASS' );
my $warn    = count_status( $res, 'WARN' );
my $ok      = $fail == 0 && ( $mode eq '--quick' || $pending == 0 );
print "STATIC-RESULT " . ( $ok ? 'ok' : 'FAILED' ) . " ($pass pass, $fail fail, $pending pending, $warn warn" . ( $mode eq '--quick' ? ', quick' : '' ) . ")\n";
exit( $ok ? 0 : 1 );
