#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-2.0
#
# (c) 2010-2018 Joe Perches <joe@perches.com>
use warnings;
use File::Basename;
use Cwd 'abs_path';
use Term::ANSIColor qw(:constants);
use Encode qw(decode encode);
my $D = dirname(abs_path($P));
my $verbose = 0;
my %verbose_messages = ();
my %verbose_emitted = ();
my $showfile = 0;
my $git = 0;
my %git_commits = ();
my $list_types = 0;
my $gitroot = $ENV{'GIT_DIR'};
$gitroot = ".git" if !defined($gitroot);
my $max_line_length = 100;
my $codespell = 0;
my $codespellfile = "/usr/share/codespell/dictionary.txt";
my $user_codespellfile = "";
my $conststructsfile = "$D/const_structs.checkpatch";
my $docsfile = "$D/../Documentation/dev-tools/checkpatch.rst";
my $typedefsfile;
my $color = "auto";
my $allow_c99_comments = 1; # Can be overridden by --ignore C99_COMMENT_TOLERANCE
# git output parsing needs US English output, so first set backtick child process LANGUAGE
my $git_command ='export LANGUAGE=en_US.UTF-8; git';
my $tabsize = 8;
my ${CONFIG_} = "CONFIG_";
  -v, --verbose              verbose mode
  --showfile                 emit diffed file position, not input file position
  -g, --git                  treat FILE as a single commit or git revision range
                             single git commit with:
                               <rev>
                               <rev>^
                               <rev>~n
                             multiple git commits with:
                               <rev1>..<rev2>
                               <rev1>...<rev2>
                               <rev>-<count>
                             git merges are ignored
  --list-types               list the possible message types
  --show-types               show the specific message type in the output
  --max-line-length=n        set the maximum line length, (default $max_line_length)
                             if exceeded, warn on patches
                             requires --strict for use with --file
  --tab-size=n               set the number of spaces for tab (default $tabsize)
  --codespell                Use the codespell dictionary for spelling/typos
                             (default:$codespellfile)
  --codespellfile            Use this codespell dictionary
  --typedefsfile             Read additional types from this file
  --color[=WHEN]             Use colors 'always', 'never', or only when output
                             is a terminal ('auto'). Default is 'auto'.
  --kconfig-prefix=WORD      use WORD as a prefix for Kconfig symbols (default
                             ${CONFIG_})
sub uniq {
	my %seen;
	return grep { !$seen{$_}++ } @_;
}

sub list_types {
	my ($exitcode) = @_;

	my $count = 0;

	local $/ = undef;

	open(my $script, '<', abs_path($P)) or
	    die "$P: Can't read '$P' $!\n";

	my $text = <$script>;
	close($script);

	my %types = ();
	# Also catch when type or level is passed through a variable
	while ($text =~ /(?:(\bCHK|\bWARN|\bERROR|&\{\$msg_level})\s*\(|\$msg_type\s*=)\s*"([^"]+)"/g) {
		if (defined($1)) {
			if (exists($types{$2})) {
				$types{$2} .= ",$1" if ($types{$2} ne $1);
			} else {
				$types{$2} = $1;
			}
		} else {
			$types{$2} = "UNDETERMINED";
		}
	}

	print("#\tMessage type\n\n");
	if ($color) {
		print(" ( Color coding: ");
		print(RED . "ERROR" . RESET);
		print(" | ");
		print(YELLOW . "WARNING" . RESET);
		print(" | ");
		print(GREEN . "CHECK" . RESET);
		print(" | ");
		print("Multiple levels / Undetermined");
		print(" )\n\n");
	}

	foreach my $type (sort keys %types) {
		my $orig_type = $type;
		if ($color) {
			my $level = $types{$type};
			if ($level eq "ERROR") {
				$type = RED . $type . RESET;
			} elsif ($level eq "WARN") {
				$type = YELLOW . $type . RESET;
			} elsif ($level eq "CHK") {
				$type = GREEN . $type . RESET;
			}
		}
		print(++$count . "\t" . $type . "\n");
		if ($verbose && exists($verbose_messages{$orig_type})) {
			my $message = $verbose_messages{$orig_type};
			$message =~ s/\n/\n\t/g;
			print("\t" . $message . "\n\n");
		}
	}

	exit($exitcode);
}

sub load_docs {
	open(my $docs, '<', "$docsfile")
	    or warn "$P: Can't read the documentation file $docsfile $!\n";

	my $type = '';
	my $desc = '';
	my $in_desc = 0;

	while (<$docs>) {
		chomp;
		my $line = $_;
		$line =~ s/\s+$//;

		if ($line =~ /^\s*\*\*(.+)\*\*$/) {
			if ($desc ne '') {
				$verbose_messages{$type} = trim($desc);
			}
			$type = $1;
			$desc = '';
			$in_desc = 1;
		} elsif ($in_desc) {
			if ($line =~ /^(?:\s{4,}|$)/) {
				$line =~ s/^\s{4}//;
				$desc .= $line;
				$desc .= "\n";
			} else {
				$verbose_messages{$type} = trim($desc);
				$type = '';
				$desc = '';
				$in_desc = 0;
			}
		}
	}

	if ($desc ne '') {
		$verbose_messages{$type} = trim($desc);
	}
	close($docs);
}

# Perl's Getopt::Long allows options to take optional arguments after a space.
# Prevent --color by itself from consuming other arguments
foreach (@ARGV) {
	if ($_ eq "--color" || $_ eq "-color") {
		$_ = "--color=$color";
	}
}

	'v|verbose!'	=> \$verbose,
	'showfile!'	=> \$showfile,
	'g|git!'	=> \$git,
	'list-types!'	=> \$list_types,
	'tab-size=i'	=> \$tabsize,
	'codespell!'	=> \$codespell,
	'codespellfile=s'	=> \$user_codespellfile,
	'typedefsfile=s'	=> \$typedefsfile,
	'color=s'	=> \$color,
	'no-color'	=> \$color,	#keep old behaviors of -nocolor
	'nocolor'	=> \$color,	#keep old behaviors of -nocolor
	'kconfig-prefix=s'	=> \${CONFIG_},
) or $help = 2;

if ($user_codespellfile) {
	# Use the user provided codespell file unconditionally
	$codespellfile = $user_codespellfile;
} elsif (!(-f $codespellfile)) {
	# If /usr/share/codespell/dictionary.txt is not present, try to find it
	# under codespell's install directory: <codespell_root>/data/dictionary.txt
	if (($codespell || $help) && which("python3") ne "") {
		my $python_codespell_dict = << "EOF";

import os.path as op
import codespell_lib
codespell_dir = op.dirname(codespell_lib.__file__)
codespell_file = op.join(codespell_dir, 'data', 'dictionary.txt')
print(codespell_file, end='')
EOF

		my $codespell_dict = `python3 -c "$python_codespell_dict" 2> /dev/null`;
		$codespellfile = $codespell_dict if (-f $codespell_dict);
	}
}

# $help is 1 if either -h, --help or --version is passed as option - exitcode: 0
# $help is 2 if invalid option is passed - exitcode: 1
help($help - 1) if ($help);

die "$P: --git cannot be used with --file or --fix\n" if ($git && ($file || $fix));
die "$P: --verbose cannot be used with --terse\n" if ($verbose && $terse);

if ($color =~ /^[01]$/) {
	$color = !$color;
} elsif ($color =~ /^always$/i) {
	$color = 1;
} elsif ($color =~ /^never$/i) {
	$color = 0;
} elsif ($color =~ /^auto$/i) {
	$color = (-t STDOUT);
} else {
	die "$P: Invalid color mode: $color\n";
}
load_docs() if ($verbose);
list_types(0) if ($list_types);
my $perl_version_ok = 1;
	$perl_version_ok = 0;
	exit(1) if (!$ignore_perl_version);
#if no filenames are given, push '-' to read patch from stdin
	push(@ARGV, '-');
# skip TAB size 1 to avoid additional checks on $tabsize - 1
die "$P: Invalid TAB size: $tabsize\n" if ($tabsize < 2);

	if (keys %$hashRef) {
		print "\nNOTE: $prefix message types:";
		print "\n";
			__refconst|
			__refdata|
			__rcu|
			__private
			volatile|
			__bitwise|
			__pure|
			__ro_after_init|
			__weak|
			__alloc_size\s*\(\s*\d+\s*(?:,\s*\d+\s*)?\)
our $String	= qr{(?:\b[Lu])?"[X\t]*"};
our $BasicType;
our $typeC99Typedefs = qr{(?:__)?(?:[us]_?)?int_?(?:8|16|32|64)_t};
our $typeOtherOSTypedefs = qr{(?x:
	u_(?:char|short|int|long) |          # bsd
	u(?:nchar|short|int|long)            # sysv
)};
our $typeKernelTypedefs = qr{(?x:
our $typeTypedefs = qr{(?x:
	$typeC99Typedefs\b|
	$typeOtherOSTypedefs\b|
	$typeKernelTypedefs\b
)};

our $zero_initializer = qr{(?:(?:0[xX])?0+$Int_type?|NULL|false)\b};
	printk(?:_ratelimited|_once|_deferred_once|_deferred|)|
	TP_printk|
our $allocFunctions = qr{(?x:
	(?:(?:devm_)?
		(?:kv|k|v)[czm]alloc(?:_array)?(?:_node)? |
		kstrdup(?:_const)? |
		kmemdup(?:_nul)?) |
	(?:\w+)?alloc_skb(?:_ip_align)? |
				# dev_alloc_skb/netdev_alloc_skb, et al
	dma_alloc_coherent
)};

	Co-developed-by:|
our $tracing_logging_tags = qr{(?xi:
	[=-]*> |
	<[=-]* |
	\[ |
	\] |
	start |
	called |
	entered |
	entry |
	enter |
	in |
	inside |
	here |
	begin |
	exit |
	end |
	done |
	leave |
	completed |
	out |
	return |
	[\.\!:\s]*
)};

sub edit_distance_min {
	my (@arr) = @_;
	my $len = scalar @arr;
	if ((scalar @arr) < 1) {
		# if underflow, return
		return;
	}
	my $min = $arr[0];
	for my $i (0 .. ($len-1)) {
		if ($arr[$i] < $min) {
			$min = $arr[$i];
		}
	}
	return $min;
}

sub get_edit_distance {
	my ($str1, $str2) = @_;
	$str1 = lc($str1);
	$str2 = lc($str2);
	$str1 =~ s/-//g;
	$str2 =~ s/-//g;
	my $len1 = length($str1);
	my $len2 = length($str2);
	# two dimensional array storing minimum edit distance
	my @distance;
	for my $i (0 .. $len1) {
		for my $j (0 .. $len2) {
			if ($i == 0) {
				$distance[$i][$j] = $j;
			} elsif ($j == 0) {
				$distance[$i][$j] = $i;
			} elsif (substr($str1, $i-1, 1) eq substr($str2, $j-1, 1)) {
				$distance[$i][$j] = $distance[$i - 1][$j - 1];
			} else {
				my $dist1 = $distance[$i][$j - 1]; #insert distance
				my $dist2 = $distance[$i - 1][$j]; # remove
				my $dist3 = $distance[$i - 1][$j - 1]; #replace
				$distance[$i][$j] = 1 + edit_distance_min($dist1, $dist2, $dist3);
			}
		}
	}
	return $distance[$len1][$len2];
}

sub find_standard_signature {
	my ($sign_off) = @_;
	my @standard_signature_tags = (
		'Signed-off-by:', 'Co-developed-by:', 'Acked-by:', 'Tested-by:',
		'Reviewed-by:', 'Reported-by:', 'Suggested-by:'
	);
	foreach my $signature (@standard_signature_tags) {
		return $signature if (get_edit_distance($sign_off, $signature) <= 2);
	}

	return "";
}


our $C90_int_types = qr{(?x:
	long\s+long\s+int\s+(?:un)?signed|
	long\s+long\s+(?:un)?signed\s+int|
	long\s+long\s+(?:un)?signed|
	(?:(?:un)?signed\s+)?long\s+long\s+int|
	(?:(?:un)?signed\s+)?long\s+long|
	int\s+long\s+long\s+(?:un)?signed|
	int\s+(?:(?:un)?signed\s+)?long\s+long|

	long\s+int\s+(?:un)?signed|
	long\s+(?:un)?signed\s+int|
	long\s+(?:un)?signed|
	(?:(?:un)?signed\s+)?long\s+int|
	(?:(?:un)?signed\s+)?long|
	int\s+long\s+(?:un)?signed|
	int\s+(?:(?:un)?signed\s+)?long|

	int\s+(?:un)?signed|
	(?:(?:un)?signed\s+)?int
)};

our @typeListFile = ();
our @modifierListFile = ();
	["(?:CLASS|DEVICE|SENSOR|SENSOR_DEVICE|IIO_DEVICE)_ATTR", 2],
	["IIO_DEV_ATTR_[A-Z_]+", 1],
	["SENSOR_(?:DEVICE_|)ATTR_2", 2],
	["SENSOR_TEMPLATE(?:_2|)", 3],
	["__ATTR", 2],
my $word_pattern = '\b[A-Z]?[a-z]{2,}\b';

$mode_perms_search = "(?:${mode_perms_search})";

our %deprecated_apis = (
	"synchronize_rcu_bh"			=> "synchronize_rcu",
	"synchronize_rcu_bh_expedited"		=> "synchronize_rcu_expedited",
	"call_rcu_bh"				=> "call_rcu",
	"rcu_barrier_bh"			=> "rcu_barrier",
	"synchronize_sched"			=> "synchronize_rcu",
	"synchronize_sched_expedited"		=> "synchronize_rcu_expedited",
	"call_rcu_sched"			=> "call_rcu",
	"rcu_barrier_sched"			=> "rcu_barrier",
	"get_state_synchronize_sched"		=> "get_state_synchronize_rcu",
	"cond_synchronize_sched"		=> "cond_synchronize_rcu",
);

#Create a search pattern for all these strings to speed up a loop below
our $deprecated_apis_search = "";
foreach my $entry (keys %deprecated_apis) {
	$deprecated_apis_search .= '|' if ($deprecated_apis_search ne "");
	$deprecated_apis_search .= $entry;
}
$deprecated_apis_search = "(?:${deprecated_apis_search})";

our $mode_perms_world_writable = qr{
	S_IWUGO		|
	S_IWOTH		|
	S_IRWXUGO	|
	S_IALLUGO	|
	0[0-7][0-7][2367]
}x;

our %mode_permission_string_types = (
	"S_IRWXU" => 0700,
	"S_IRUSR" => 0400,
	"S_IWUSR" => 0200,
	"S_IXUSR" => 0100,
	"S_IRWXG" => 0070,
	"S_IRGRP" => 0040,
	"S_IWGRP" => 0020,
	"S_IXGRP" => 0010,
	"S_IRWXO" => 0007,
	"S_IROTH" => 0004,
	"S_IWOTH" => 0002,
	"S_IXOTH" => 0001,
	"S_IRWXUGO" => 0777,
	"S_IRUGO" => 0444,
	"S_IWUGO" => 0222,
	"S_IXUGO" => 0111,
);

#Create a search pattern for all these strings to speed up a loop below
our $mode_perms_string_search = "";
foreach my $entry (keys %mode_permission_string_types) {
	$mode_perms_string_search .= '|' if ($mode_perms_string_search ne "");
	$mode_perms_string_search .= $entry;
}
our $single_mode_perms_string_search = "(?:${mode_perms_string_search})";
our $multi_mode_perms_string_search = qr{
	${single_mode_perms_string_search}
	(?:\s*\|\s*${single_mode_perms_string_search})*
}x;

sub perms_to_octal {
	my ($string) = @_;

	return trim($string) if ($string =~ /^\s*0[0-7]{3,3}\s*$/);

	my $val = "";
	my $oval = "";
	my $to = 0;
	my $curpos = 0;
	my $lastpos = 0;
	while ($string =~ /\b(($single_mode_perms_string_search)\b(?:\s*\|\s*)?\s*)/g) {
		$curpos = pos($string);
		my $match = $2;
		my $omatch = $1;
		last if ($lastpos > 0 && ($curpos - length($omatch) != $lastpos));
		$lastpos = $curpos;
		$to |= $mode_permission_string_types{$match};
		$val .= '\s*\|\s*' if ($val ne "");
		$val .= $match;
		$oval .= $omatch;
	}
	$oval =~ s/^\s*\|\s*//;
	$oval =~ s/\s*\|\s*$//;
	return sprintf("%04o", $to);
}
if (open(my $spelling, '<', $spelling_file)) {
	while (<$spelling>) {
		my $line = $_;

		$line =~ s/\s*\n?$//g;
		$line =~ s/^\s*//g;

		next if ($line =~ m/^\s*#/);
		next if ($line =~ m/^\s*$/);

		my ($suspect, $fix) = split(/\|\|/, $line);

		$spelling_fix{$suspect} = $fix;
	}
	close($spelling);
} else {
	warn "No typos will be found - file '$spelling_file': $!\n";
}

if ($codespell) {
	if (open(my $spelling, '<', $codespellfile)) {
		while (<$spelling>) {
			my $line = $_;

			$line =~ s/\s*\n?$//g;
			$line =~ s/^\s*//g;

			next if ($line =~ m/^\s*#/);
			next if ($line =~ m/^\s*$/);
			next if ($line =~ m/, disabled/i);

			$line =~ s/,.*$//;

			my ($suspect, $fix) = split(/->/, $line);

			$spelling_fix{$suspect} = $fix;
		}
		close($spelling);
	} else {
		warn "No codespell typos will be found - file '$codespellfile': $!\n";
	}
}

$misspellings = join("|", sort keys %spelling_fix) if keys %spelling_fix;

sub read_words {
	my ($wordsRef, $file) = @_;

	if (open(my $words, '<', $file)) {
		while (<$words>) {
			my $line = $_;

			$line =~ s/\s*\n?$//g;
			$line =~ s/^\s*//g;

			next if ($line =~ m/^\s*#/);
			next if ($line =~ m/^\s*$/);
			if ($line =~ /\s/) {
				print("$file: '$line' invalid - ignored\n");
				next;
			}

			$$wordsRef .= '|' if (defined $$wordsRef);
			$$wordsRef .= $line;
		}
		close($file);
		return 1;
	}
	return 0;
}
my $const_structs;
if (show_type("CONST_STRUCT")) {
	read_words(\$const_structs, $conststructsfile)
	    or warn "No structs that should be const will be found - file '$conststructsfile': $!\n";
}
if (defined($typedefsfile)) {
	my $typeOtherTypedefs;
	read_words(\$typeOtherTypedefs, $typedefsfile)
	    or warn "No additional types will be considered - file '$typedefsfile': $!\n";
	$typeTypedefs .= '|' . $typeOtherTypedefs if (defined $typeOtherTypedefs);
	my $mods = "(?x:  \n" . join("|\n  ", (@modifierList, @modifierListFile)) . "\n)";
	my $all = "(?x:  \n" . join("|\n  ", (@typeList, @typeListFile)) . "\n)";
	$BasicType	= qr{
				(?:$typeTypedefs\b)|
				(?:${all}\b)
		}x;
			(?:(?:\s|\*|\[\])+\s*const|(?:\s|\*\s*(?:const\s*)?|\[\])+|(?:\s*\[\s*\])+){0,4}
			(?:(?:\s|\*|\[\])+\s*const|(?:\s|\*\s*(?:const\s*)?|\[\])+|(?:\s*\[\s*\])+){0,4}
our $FuncArg = qr{$Typecast{0,1}($LvalOrFunc|$Constant|$String)};
	(?:$Storage\s+)?(?:[A-Z_][A-Z0-9]*_){0,2}(?:DEFINE|DECLARE)(?:_[A-Z0-9]+){1,6}\s*\(|
	(?:$Storage\s+)?[HLP]?LIST_HEAD\s*\(|
	(?:SKCIPHER_REQUEST|SHASH_DESC|AHASH_REQUEST)_ON_STACK\s*\(
our %allow_repeated_words = (
	add => '',
	added => '',
	bad => '',
	be => '',
);

our %maintained_status = ();

sub is_maintained_obsolete {
	my ($filename) = @_;

	return 0 if (!$tree || !(-e "$root/scripts/get_maintainer.pl"));

	if (!exists($maintained_status{$filename})) {
		$maintained_status{$filename} = `perl $root/scripts/get_maintainer.pl --status --nom --nol --nogit --nogit-fallback -f $filename 2>&1`;
	}

	return $maintained_status{$filename} =~ /obsolete/i;
}

sub is_SPDX_License_valid {
	my ($license) = @_;

	return 1 if (!$tree || which("python3") eq "" || !(-x "$root/scripts/spdxcheck.py") || !(-e "$gitroot"));

	my $root_path = abs_path($root);
	my $status = `cd "$root_path"; echo "$license" | scripts/spdxcheck.py -`;
	return 0 if ($status ne "");
	return 1;
}

	if (-e "$gitroot") {
		my $git_last_include_commit = `${git_command} log --no-merges --pretty=format:"%h%n" -1 -- include`;
	if (-e "$gitroot") {
		$files = `${git_command} ls-files "include/*.h"`;
sub git_is_single_file {
	my ($filename) = @_;

	return 0 if ((which("git") eq "") || !(-e "$gitroot"));

	my $output = `${git_command} ls-files -- $filename 2>/dev/null`;
	my $count = $output =~ tr/\n//;
	return $count eq 1 && $output =~ m{^${filename}$};
}

	return ($id, $desc) if ((which("git") eq "") || !(-e "$gitroot"));
	my $output = `${git_command} log --no-color --format='%H %s' -1 $commit 2>&1`;
	return ($id, $desc) if ($#lines < 0);

	if ($lines[0] =~ /^error: short SHA1 $commit is ambiguous/) {
	} elsif ($lines[0] =~ /^fatal: ambiguous argument '$commit': unknown revision or path not in the working tree\./ ||
		 $lines[0] =~ /^fatal: bad object $commit/) {
		$id = undef;
# If input is git commits, extract all commits from the commit expressions.
# For example, HEAD-3 means we need check 'HEAD, HEAD~1, HEAD~2'.
die "$P: No git repository found\n" if ($git && !-e "$gitroot");

if ($git) {
	my @commits = ();
	foreach my $commit_expr (@ARGV) {
		my $git_range;
		if ($commit_expr =~ m/^(.*)-(\d+)$/) {
			$git_range = "-$2 $1";
		} elsif ($commit_expr =~ m/\.\./) {
			$git_range = "$commit_expr";
		} else {
			$git_range = "-1 $commit_expr";
		}
		my $lines = `${git_command} log --no-color --no-merges --pretty=format:'%H %s' $git_range`;
		foreach my $line (split(/\n/, $lines)) {
			$line =~ /^([0-9a-fA-F]{40,40}) (.*)$/;
			next if (!defined($1) || !defined($2));
			my $sha1 = $1;
			my $subject = $2;
			unshift(@commits, $sha1);
			$git_commits{$sha1} = $subject;
		}
	}
	die "$P: no git commits after extraction!\n" if (@commits == 0);
	@ARGV = @commits;
}

$allow_c99_comments = !defined $ignore_type{"C99_COMMENT_TOLERANCE"};
	my $is_git_file = git_is_single_file($filename);
	my $oldfile = $file;
	$file = 1 if ($is_git_file);
	if ($git) {
		open($FILE, '-|', "git format-patch -M --stdout -1 $filename") ||
			die "$P: $filename: git format-patch failed - $!\n";
	} elsif ($file) {
	} elsif ($git) {
		$vname = "Commit " . substr($filename, 0, 12) . ' ("' . $git_commits{$filename} . '")';
		$vname = qq("$1") if ($filename eq '-' && $_ =~ m/^Subject:\s+(.+)/i);

	if ($#ARGV > 0 && $quiet == 0) {
		print '-' x length($vname) . "\n";
		print "$vname\n";
		print '-' x length($vname) . "\n";
	}

	@modifierListFile = ();
	@typeListFile = ();
	build_types();
	$file = $oldfile if ($is_git_file);
}

if (!$quiet) {
	hash_show_words(\%use_type, "Used");
	hash_show_words(\%ignore_type, "Ignored");

	if (!$perl_version_ok) {
		print << "EOM"

NOTE: perl $^V is not modern enough to detect all possible issues.
      An upgrade to at least perl $minimum_perl_version is suggested.
EOM
	}
	if ($exit) {
		print << "EOM"

NOTE: If any of the errors are false positives, please report
      them to the maintainer, see CHECKPATCH in MAINTAINERS.
EOM
	}
	my $quoted = "";
	my $name_comment = "";
		$formatted_email =~ s/\Q$address\E.*$//;
	# Extract comments from names excluding quoted parts
	# "John D. (Doe)" - Do not extract
	if ($name =~ s/\"(.+)\"//) {
		$quoted = $1;
	}
	while ($name =~ s/\s*($balanced_parens)\s*/ /) {
		$name_comment .= trim($1);
	}
	$name =~ s/^[ \"]+|[ \"]+$//g;
	$name = trim("$quoted $name");

	$comment = trim($comment);
	return ($name, $name_comment, $address, $comment);
	my ($name, $name_comment, $address, $comment) = @_;
	$name =~ s/^[ \"]+|[ \"]+$//g;
	$address =~ s/(?:\.|\,|\")+$//; ##trailing commas, dots or quotes
	$name_comment = trim($name_comment);
	$name_comment = " $name_comment" if ($name_comment ne "");
	$comment = trim($comment);
	$comment = " $comment" if ($comment ne "");

		$formatted_email = "$name$name_comment <$address>";
	$formatted_email .= "$comment";
sub reformat_email {
	my ($email) = @_;

	my ($email_name, $name_comment, $email_address, $comment) = parse_email($email);
	return format_email($email_name, $name_comment, $email_address, $comment);
}

sub same_email_addresses {
	my ($email1, $email2) = @_;

	my ($email1_name, $name1_comment, $email1_address, $comment1) = parse_email($email1);
	my ($email2_name, $name2_comment, $email2_address, $comment2) = parse_email($email2);

	return $email1_name eq $email2_name &&
	       $email1_address eq $email2_address &&
	       $name1_comment eq $name2_comment &&
	       $comment1 eq $comment2;
}

			for (; ($n % $tabsize) != 0; $n++) {
		# Comments we are whacking completely including the begin
	if ($allow_c99_comments && $res =~ m@(//.*$)@) {
		my $match = $1;
		$res =~ s/\Q$match\E/"$;" x length($match)/e;
	}

	return "" if (!defined($line) || !defined($rawline));
	return "" if ($line !~ m/($String)/g);
	# If c99 comment on the current line, or the line before or after
	my ($current_comment) = ($rawlines[$end_line - 1] =~ m@^\+.*(//.*$)@);
	return $current_comment if (defined $current_comment);
	($current_comment) = ($rawlines[$end_line - 2] =~ m@^[\+ ].*(//.*$)@);
	return $current_comment if (defined $current_comment);
	($current_comment) = ($rawlines[$end_line] =~ m@^[\+ ].*(//.*$)@);
	return $current_comment if (defined $current_comment);

	($current_comment) = ($rawlines[$end_line - 1] =~ m@.*(/\*.*\*/)\s*(?:\\\s*)?$@);
sub get_stat_real {
	my ($linenr, $lc) = @_;

	my $stat_real = raw_line($linenr, 0);
	for (my $count = $linenr + 1; $count <= $lc; $count++) {
		$stat_real = $stat_real . "\n" . raw_line($count, 0);
	}

	return $stat_real;
}

sub get_stat_here {
	my ($linenr, $cnt, $here) = @_;

	my $herectx = $here . "\n";
	for (my $n = 0; $n < $cnt; $n++) {
		$herectx .= raw_line($linenr, $n) . "\n";
	}

	return $herectx;
}

					push(@modifierListFile, $modifier);
			push(@typeListFile, $possible);
	$type =~ tr/[a-z]/[A-Z]/;

	my $output = '';
	if ($color) {
		if ($level eq 'ERROR') {
			$output .= RED;
		} elsif ($level eq 'WARNING') {
			$output .= YELLOW;
		} else {
			$output .= GREEN;
		}
	}
	$output .= $prefix . $level . ':';
		$output .= BLUE if ($color);
		$output .= "$type:";
	}
	$output .= RESET if ($color);
	$output .= ' ' . $msg . "\n";

	if ($showfile) {
		my @lines = split("\n", $output, -1);
		splice(@lines, 1, 1);
		$output = join("\n", @lines);
	}

	if ($terse) {
		$output = (split('\n', $output))[0] . "\n";
	}

	if ($verbose && exists($verbose_messages{$type}) &&
	    !exists($verbose_emitted{$type})) {
		$output .= $verbose_messages{$type} . "\n\n";
		$verbose_emitted{$type} = 1;
	push(our @report, $output);
		if ($line =~ /^(?:\+\+\+|\-\-\-)\s+\S+/) {	#new filename
	my $source_indent = $tabsize;
sub get_raw_comment {
	my ($line, $rawline) = @_;
	my $comment = '';

	for my $i (0 .. (length($line) - 1)) {
		if (substr($line, $i, 1) eq "$;") {
			$comment .= substr($rawline, $i, 1);
		}
	}

	return $comment;
}

sub exclude_global_initialisers {
	my ($realfile) = @_;

	# Do not check for BPF programs (tools/testing/selftests/bpf/progs/*.c, samples/bpf/*_kern.c, *.bpf.c).
	return $realfile =~ m@^tools/testing/selftests/bpf/progs/.*\.c$@ ||
		$realfile =~ m@^samples/bpf/.*_kern\.c$@ ||
		$realfile =~ m@/bpf/.*\.bpf\.c$@;
}

	my $author = '';
	my $authorsignoff = 0;
	my $author_sob = '';
	my $is_binding_patch = -1;
	my $has_patch_separator = 0;	#Found a --- line
	my $has_commit_log = 0;		#Encountered lines before patch
	my $commit_log_lines = 0;	#Number of commit log lines
	my $commit_log_possible_stack_dump = 0;
	my $commit_log_long_line = 0;
	my $commit_log_has_diff = 0;
	my $last_git_commit_id_linenr = -1;

	my $last_coalesced_string_linenr = -1;
	my $context_function;		#undef'd unless there's a known function
	my $checklicenseline = 1;

			if ($1 =~ m@Documentation/admin-guide/kernel-parameters.txt$@) {
		if ($rawline =~ /^\@\@ -\d+(?:,\d+)? \+(\d+)(,(\d+))? \@\@/) {
		my $raw_comment = get_raw_comment($line, $rawline);

# check if it's a mode change, rename or start of a patch
		if (!$in_commit_log &&
		    ($line =~ /^ mode change [0-7]+ => [0-7]+ \S+\s*$/ ||
		    ($line =~ /^rename (?:from|to) \S+\s*$/ ||
		     $line =~ /^diff --git a\/[\w\/\.\_\-]+ b\/\S+\s*$/))) {
			$is_patch = 1;
		}
		if (!$in_commit_log &&
		    $line =~ /^\@\@ -\d+(?:,\d+)? \+(\d+)(,(\d+))? \@\@(.*)/) {
			my $context = $4;
			if ($context =~ /\b(\w+)\s*\(/) {
				$context_function = $1;
			} else {
				undef $context_function;
			}
#make up the handle for any error we report on this line
		if ($showfile) {
			$prefix = "$realfile:$realline: "
		} elsif ($emacs) {
			if ($file) {
				$prefix = "$filename:$realline: ";
			} else {
				$prefix = "$filename:$linenr: ";
			}
		}

			if (is_maintained_obsolete($realfile)) {
				WARN("OBSOLETE",
				     "$realfile is marked as 'obsolete' in the MAINTAINERS hierarchy.  No unnecessary modifications please.\n");
			}
			if ($realfile =~ m@^(?:drivers/net/|net/|drivers/staging/)@) {
			$checklicenseline = 1;

			if ($realfile !~ /^MAINTAINERS/) {
				my $last_binding_patch = $is_binding_patch;

				$is_binding_patch = () = $realfile =~ m@^(?:Documentation/devicetree/|include/dt-bindings/)@;

				if (($last_binding_patch != -1) &&
				    ($last_binding_patch ^ $is_binding_patch)) {
					WARN("DT_SPLIT_BINDING_PATCH",
					     "DT binding docs and includes should be a separate patch. See: Documentation/devicetree/bindings/submitting-patches.rst\n");
				}
			}

# Verify the existence of a commit log if appropriate
# 2 is used because a $signature is counted in $commit_log_lines
		if ($in_commit_log) {
			if ($line !~ /^\s*$/) {
				$commit_log_lines++;	#could be a $signature
			}
		} elsif ($has_commit_log && $commit_log_lines < 2) {
			WARN("COMMIT_MESSAGE",
			     "Missing commit description - Add an appropriate one\n");
			$commit_log_lines = 2;	#warn only once
		}

# Check if the commit log has what seems like a diff which can confuse patch
		if ($in_commit_log && !$commit_log_has_diff &&
		    (($line =~ m@^\s+diff\b.*a/([\w/]+)@ &&
		      $line =~ m@^\s+diff\b.*a/[\w/]+\s+b/$1\b@) ||
		     $line =~ m@^\s*(?:\-\-\-\s+a/|\+\+\+\s+b/)@ ||
		     $line =~ m/^\s*\@\@ \-\d+,\d+ \+\d+,\d+ \@\@/)) {
			ERROR("DIFF_IN_COMMIT_MSG",
			      "Avoid using diff content in the commit message - patch(1) might not work\n" . $herecurr);
			$commit_log_has_diff = 1;
		}

# Check the patch for a From:
		if (decode("MIME-Header", $line) =~ /^From:\s*(.*)/) {
			$author = $1;
			my $curline = $linenr;
			while(defined($rawlines[$curline]) && ($rawlines[$curline++] =~ /^[ \t]\s*(.*)/)) {
				$author .= $1;
			}
			$author = encode("utf8", $author) if ($line =~ /=\?utf-8\?/i);
			$author =~ s/"//g;
			$author = reformat_email($author);
		}

		if ($line =~ /^\s*signed-off-by:\s*(.*)/i) {
			if ($author ne ''  && $authorsignoff != 1) {
				if (same_email_addresses($1, $author)) {
					$authorsignoff = 1;
				} else {
					my $ctx = $1;
					my ($email_name, $email_comment, $email_address, $comment1) = parse_email($ctx);
					my ($author_name, $author_comment, $author_address, $comment2) = parse_email($author);

					if (lc $email_address eq lc $author_address && $email_name eq $author_name) {
						$author_sob = $ctx;
						$authorsignoff = 2;
					} elsif (lc $email_address eq lc $author_address) {
						$author_sob = $ctx;
						$authorsignoff = 3;
					} elsif ($email_name eq $author_name) {
						$author_sob = $ctx;
						$authorsignoff = 4;

						my $address1 = $email_address;
						my $address2 = $author_address;

						if ($address1 =~ /(\S+)\+\S+(\@.*)/) {
							$address1 = "$1$2";
						}
						if ($address2 =~ /(\S+)\+\S+(\@.*)/) {
							$address2 = "$1$2";
						}
						if ($address1 eq $address2) {
							$authorsignoff = 5;
						}
					}
				}
			}
		}

# Check for patch separator
		if ($line =~ /^---$/) {
			$has_patch_separator = 1;
			$in_commit_log = 0;
		}

# Check if MAINTAINERS is being updated.  If so, there's probably no need to
# emit the "does MAINTAINERS need updating?" message on file add/move/delete
		if ($line =~ /^\s*MAINTAINERS\s*\|/) {
			$reported_maintainer_file = 1;
		}

# Check signature styles
		if (!$in_header_lines &&
		    $line =~ /^(\s*)([a-z0-9_-]+by:|$signature_tags)(\s*)(.*)/i) {
			my $space_before = $1;
				my $suggested_signature = find_standard_signature($sign_off);
				if ($suggested_signature eq "") {
					WARN("BAD_SIGN_OFF",
					     "Non-standard signature: $sign_off\n" . $herecurr);
				} else {
					if (WARN("BAD_SIGN_OFF",
						 "Non-standard signature: '$sign_off' - perhaps '$suggested_signature'?\n" . $herecurr) &&
					    $fix) {
						$fixed[$fixlinenr] =~ s/$sign_off/$suggested_signature/;
					}
				}
			my ($email_name, $name_comment, $email_address, $comment) = parse_email($email);
			my $suggested_email = format_email(($email_name, $name_comment, $email_address, $comment));
				if (!same_email_addresses($email, $suggested_email)) {
					if (WARN("BAD_SIGN_OFF",
						 "email address '$email' might be better as '$suggested_email'\n" . $herecurr) &&
					    $fix) {
						$fixed[$fixlinenr] =~ s/\Q$email\E/$suggested_email/;
					}
				}

				# Address part shouldn't have comments
				my $stripped_address = $email_address;
				$stripped_address =~ s/\([^\(\)]*\)//g;
				if ($email_address ne $stripped_address) {
					if (WARN("BAD_SIGN_OFF",
						 "address part of email should not have comments: '$email_address'\n" . $herecurr) &&
					    $fix) {
						$fixed[$fixlinenr] =~ s/\Q$email_address\E/$stripped_address/;
					}
				}

				# Only one name comment should be allowed
				my $comment_count = () = $name_comment =~ /\([^\)]+\)/g;
				if ($comment_count > 1) {
					     "Use a single name comment in email: '$email'\n" . $herecurr);
				}


				# stable@vger.kernel.org or stable@kernel.org shouldn't
				# have an email name. In addition comments should strictly
				# begin with a #
				if ($email =~ /^.*stable\@(?:vger\.)?kernel\.org/i) {
					if (($comment ne "" && $comment !~ /^#.+/) ||
					    ($email_name ne "")) {
						my $cur_name = $email_name;
						my $new_comment = $comment;
						$cur_name =~ s/[a-zA-Z\s\-\"]+//g;

						# Remove brackets enclosing comment text
						# and # from start of comments to get comment text
						$new_comment =~ s/^\((.*)\)$/$1/;
						$new_comment =~ s/^\[(.*)\]$/$1/;
						$new_comment =~ s/^[\s\#]+|\s+$//g;

						$new_comment = trim("$new_comment $cur_name") if ($cur_name ne $new_comment);
						$new_comment = " # $new_comment" if ($new_comment ne "");
						my $new_email = "$email_address$new_comment";

						if (WARN("BAD_STABLE_ADDRESS_STYLE",
							 "Invalid email format for stable: '$email', prefer '$new_email'\n" . $herecurr) &&
						    $fix) {
							$fixed[$fixlinenr] =~ s/\Q$email\E/$new_email/;
						}
					}
				} elsif ($comment ne "" && $comment !~ /^(?:#.+|\(.+\))$/) {
					my $new_comment = $comment;

					# Extract comment text from within brackets or
					# c89 style /*...*/ comments
					$new_comment =~ s/^\[(.*)\]$/$1/;
					$new_comment =~ s/^\/\*(.*)\*\/$/$1/;

					$new_comment = trim($new_comment);
					$new_comment =~ s/^[^\w]$//; # Single lettered comment with non word character is usually a typo
					$new_comment = "($new_comment)" if ($new_comment ne "");
					my $new_email = format_email($email_name, $name_comment, $email_address, $new_comment);

					if (WARN("BAD_SIGN_OFF",
						 "Unexpected content after email: '$email', should be: '$new_email'\n" . $herecurr) &&
					    $fix) {
						$fixed[$fixlinenr] =~ s/\Q$email\E/$new_email/;
					}

# Check Co-developed-by: immediately followed by Signed-off-by: with same name and email
			if ($sign_off =~ /^co-developed-by:$/i) {
				if ($email eq $author) {
					WARN("BAD_SIGN_OFF",
					      "Co-developed-by: should not be used to attribute nominal patch author '$author'\n" . "$here\n" . $rawline);
				}
				if (!defined $lines[$linenr]) {
					WARN("BAD_SIGN_OFF",
					     "Co-developed-by: must be immediately followed by Signed-off-by:\n" . "$here\n" . $rawline);
				} elsif ($rawlines[$linenr] !~ /^\s*signed-off-by:\s*(.*)/i) {
					WARN("BAD_SIGN_OFF",
					     "Co-developed-by: must be immediately followed by Signed-off-by:\n" . "$here\n" . $rawline . "\n" .$rawlines[$linenr]);
				} elsif ($1 ne $email) {
					WARN("BAD_SIGN_OFF",
					     "Co-developed-by and Signed-off-by: name/email do not match \n" . "$here\n" . $rawline . "\n" .$rawlines[$linenr]);
				}
			}
# Check email subject for common tools that don't need to be mentioned
		if ($in_header_lines &&
		    $line =~ /^Subject:.*\b(?:checkpatch|sparse|smatch)\b[^:]/i) {
			WARN("EMAIL_SUBJECT",
			     "A patch subject line should describe the change not the tool that found it\n" . $herecurr);
# Check for Gerrit Change-Ids not in any patch context
		if ($realfile eq '' && !$has_patch_separator && $line =~ /^\s*change-id:/i) {
			if (ERROR("GERRIT_CHANGE_ID",
			          "Remove Gerrit Change-Id's before submitting upstream\n" . $herecurr) &&
			    $fix) {
				fix_delete_line($fixlinenr, $rawline);
			}
# Check if the commit log is in a possible stack dump
		if ($in_commit_log && !$commit_log_possible_stack_dump &&
		    ($line =~ /^\s*(?:WARNING:|BUG:)/ ||
		     $line =~ /^\s*\[\s*\d+\.\d{6,6}\s*\]/ ||
					# timestamp
		     $line =~ /^\s*\[\<[0-9a-fA-F]{8,}\>\]/) ||
		     $line =~ /^(?:\s+\w+:\s+[0-9a-fA-F]+){3,3}/ ||
		     $line =~ /^\s*\#\d+\s*\[[0-9a-fA-F]+\]\s*\w+ at [0-9a-fA-F]+/) {
					# stack dump address styles
			$commit_log_possible_stack_dump = 1;
		}

# Check for line lengths > 75 in commit log, warn once
		if ($in_commit_log && !$commit_log_long_line &&
		    length($line) > 75 &&
		    !($line =~ /^\s*[a-zA-Z0-9_\/\.]+\s+\|\s+\d+/ ||
					# file delta changes
		      $line =~ /^\s*(?:[\w\.\-\+]*\/)++[\w\.\-\+]+:/ ||
					# filename then :
		      $line =~ /^\s*(?:Fixes:|Link:|$signature_tags)/i ||
					# A Fixes: or Link: line or signature tag line
		      $commit_log_possible_stack_dump)) {
			WARN("COMMIT_LOG_LONG_LINE",
			     "Possible unwrapped commit description (prefer a maximum 75 chars per line)\n" . $herecurr);
			$commit_log_long_line = 1;
		}

# Reset possible stack dump if a blank line is found
		if ($in_commit_log && $commit_log_possible_stack_dump &&
		    $line =~ /^\s*$/) {
			$commit_log_possible_stack_dump = 0;
		}

# Check for lines starting with a #
		if ($in_commit_log && $line =~ /^#/) {
			if (WARN("COMMIT_COMMENT_SYMBOL",
				 "Commit log lines starting with '#' are dropped by git as comments\n" . $herecurr) &&
			    $fix) {
				$fixed[$fixlinenr] =~ s/^/ /;
			}
		}

# Check for git id commit length and improperly formed commit descriptions
# A correctly formed commit description is:
#    commit <SHA-1 hash length 12+ chars> ("Complete commit subject")
# with the commit subject '("' prefix and '")' suffix
# This is a fairly compilicated block as it tests for what appears to be
# bare SHA-1 hash with  minimum length of 5.  It also avoids several types of
# possible SHA-1 matches.
# A commit match can span multiple lines so this block attempts to find a
# complete typical commit on a maximum of 3 lines
		if ($perl_version_ok &&
		    $in_commit_log && !$commit_log_possible_stack_dump &&
		    $line !~ /^\s*(?:Link|Patchwork|http|https|BugLink|base-commit):/i &&
		    $line !~ /^This reverts commit [0-9a-f]{7,40}/ &&
		    (($line =~ /\bcommit\s+[0-9a-f]{5,}\b/i ||
		      ($line =~ /\bcommit\s*$/i && defined($rawlines[$linenr]) && $rawlines[$linenr] =~ /^\s*[0-9a-f]{5,}\b/i)) ||
		     ($line =~ /(?:\s|^)[0-9a-f]{12,40}(?:[\s"'\(\[]|$)/i &&
		      $line !~ /[\<\[][0-9a-f]{12,40}[\>\]]/i &&
		      $line !~ /\bfixes:\s*[0-9a-f]{12,40}/i))) {
			my $init_char = "c";
			my $orig_commit = "";
			my $short = 1;
			my $long = 0;
			my $case = 1;
			my $space = 1;
			my $id = '0123456789ab';
			my $orig_desc = "commit description";
			my $description = "";
			my $herectx = $herecurr;
			my $has_parens = 0;
			my $has_quotes = 0;

			my $input = $line;
			if ($line =~ /(?:\bcommit\s+[0-9a-f]{5,}|\bcommit\s*$)/i) {
				for (my $n = 0; $n < 2; $n++) {
					if ($input =~ /\bcommit\s+[0-9a-f]{5,}\s*($balanced_parens)/i) {
						$orig_desc = $1;
						$has_parens = 1;
						# Always strip leading/trailing parens then double quotes if existing
						$orig_desc = substr($orig_desc, 1, -1);
						if ($orig_desc =~ /^".*"$/) {
							$orig_desc = substr($orig_desc, 1, -1);
							$has_quotes = 1;
						}
						last;
					}
					last if ($#lines < $linenr + $n);
					$input .= " " . trim($rawlines[$linenr + $n]);
					$herectx .= "$rawlines[$linenr + $n]\n";
				}
				$herectx = $herecurr if (!$has_parens);
			}

			if ($input =~ /\b(c)ommit\s+([0-9a-f]{5,})\b/i) {
				$init_char = $1;
				$orig_commit = lc($2);
				$short = 0 if ($input =~ /\bcommit\s+[0-9a-f]{12,40}/i);
				$long = 1 if ($input =~ /\bcommit\s+[0-9a-f]{41,}/i);
				$space = 0 if ($input =~ /\bcommit [0-9a-f]/i);
				$case = 0 if ($input =~ /\b[Cc]ommit\s+[0-9a-f]{5,40}[^A-F]/);
			} elsif ($input =~ /\b([0-9a-f]{12,40})\b/i) {
				$orig_commit = lc($1);
			}

			($id, $description) = git_commit_info($orig_commit,
							      $id, $orig_desc);

			if (defined($id) &&
			    ($short || $long || $space || $case || ($orig_desc ne $description) || !$has_quotes) &&
			    $last_git_commit_id_linenr != $linenr - 1) {
				ERROR("GIT_COMMIT_ID",
				      "Please use git commit description style 'commit <12+ chars of sha1> (\"<title line>\")' - ie: '${init_char}ommit $id (\"$description\")'\n" . $herectx);
			}
			#don't report the next line if this line ends in commit and the sha1 hash is the next line
			$last_git_commit_id_linenr = $linenr if ($line =~ /\bcommit\s*$/i);
			$is_patch = 1;
# Check for adding new DT bindings not in schema format
		if (!$in_commit_log &&
		    ($line =~ /^new file mode\s*\d+\s*$/) &&
		    ($realfile =~ m@^Documentation/devicetree/bindings/.*\.txt$@)) {
			WARN("DT_SCHEMA_BINDING_PATCH",
			     "DT bindings should be in DT schema format. See: Documentation/devicetree/bindings/writing-schema.rst\n");
		}

		    !($rawline =~ /^\s+(?:\S|$)/ ||
		      $rawline =~ /^(?:commit\b|from\b|[\w-]+:)/i)) {
			$has_commit_log = 1;
# Check for absolute kernel paths in commit message
		if ($tree && $in_commit_log) {
			while ($line =~ m{(?:^|\s)(/\S*)}g) {
				my $file = $1;

				if ($file =~ m{^(.*?)(?::\d+)+:?$} &&
				    check_absolute_file($1, $herecurr)) {
					#
				} else {
					check_absolute_file($file, $herecurr);
				}
			}
		}

		if (defined($misspellings) &&
		    ($in_commit_log || $line =~ /^(?:\+|Subject:)/i)) {
			while ($rawline =~ /(?:^|[^\w\-'`])($misspellings)(?:[^\w\-'`]|$)/gi) {
				my $blank = copy_spacing($rawline);
				my $ptr = substr($blank, 0, $-[1]) . "^" x length($typo);
				my $hereptr = "$hereline$ptr\n";
				my $msg_level = \&WARN;
				$msg_level = \&CHK if ($file);
				if (&{$msg_level}("TYPO_SPELLING",
						  "'$typo' may be misspelled - perhaps '$typo_fix'?\n" . $hereptr) &&
# check for invalid commit id
		if ($in_commit_log && $line =~ /(^fixes:|\bcommit)\s+([0-9a-f]{6,40})\b/i) {
			my $id;
			my $description;
			($id, $description) = git_commit_info($2, undef, undef);
			if (!defined($id)) {
				WARN("UNKNOWN_COMMIT_ID",
				     "Unknown commit id '$2', maybe rebased or not pulled?\n" . $herecurr);
			}
		}

# check for repeated words separated by a single space
# avoid false positive from list command eg, '-rw-r--r-- 1 root root'
		if (($rawline =~ /^\+/ || $in_commit_log) &&
		    $rawline !~ /[bcCdDlMnpPs\?-][rwxsStT-]{9}/) {
			pos($rawline) = 1 if (!$in_commit_log);
			while ($rawline =~ /\b($word_pattern) (?=($word_pattern))/g) {

				my $first = $1;
				my $second = $2;
				my $start_pos = $-[1];
				my $end_pos = $+[2];
				if ($first =~ /(?:struct|union|enum)/) {
					pos($rawline) += length($first) + length($second) + 1;
					next;
				}

				next if (lc($first) ne lc($second));
				next if ($first eq 'long');

				# check for character before and after the word matches
				my $start_char = '';
				my $end_char = '';
				$start_char = substr($rawline, $start_pos - 1, 1) if ($start_pos > ($in_commit_log ? 0 : 1));
				$end_char = substr($rawline, $end_pos, 1) if ($end_pos < length($rawline));

				next if ($start_char =~ /^\S$/);
				next if (index(" \t.,;?!", $end_char) == -1);

				# avoid repeating hex occurrences like 'ff ff fe 09 ...'
				if ($first =~ /\b[0-9a-f]{2,}\b/i) {
					next if (!exists($allow_repeated_words{lc($first)}));
				}

				if (WARN("REPEATED_WORD",
					 "Possible repeated word: '$first'\n" . $herecurr) &&
				    $fix) {
					$fixed[$fixlinenr] =~ s/\b$first $second\b/$first/;
				}
			}

			# if it's a repeated word on consecutive lines in a comment block
			if ($prevline =~ /$;+\s*$/ &&
			    $prevrawline =~ /($word_pattern)\s*$/) {
				my $last_word = $1;
				if ($rawline =~ /^\+\s*\*\s*$last_word /) {
					if (WARN("REPEATED_WORD",
						 "Possible repeated word: '$last_word'\n" . $hereprev) &&
					    $fix) {
						$fixed[$fixlinenr] =~ s/(\+\s*\*\s*)$last_word /$1/;
					}
				}
			}
		}

		    $rawline =~ /\b675\s+Mass\s+Ave/i ||
			my $msg_level = \&ERROR;
			$msg_level = \&CHK if ($file);
			&{$msg_level}("FSF_MAILING_ADDRESS",
				      "Do not include the paragraph about writing to the Free Software Foundation's mailing address from the sample GPL notice. The FSF has changed addresses in the past, and may do so again. Linux already includes a copy of the GPL.\n" . $herevet)
		    # 'choice' is usually the last thing on the line (though
		    # Kconfig supports named choices), so use a word boundary
		    # (\b) rather than a whitespace character (\s)
		    $line =~ /^\+\s*(?:config|menuconfig|choice)\b/) {
			my $ln = $linenr;
			my $needs_help = 0;
			my $has_help = 0;
			my $help_length = 0;
			while (defined $lines[$ln]) {
				my $f = $lines[$ln++];
				last if ($f !~ /^[\+ ]/);	# !patch context
				if ($f =~ /^\+\s*(?:bool|tristate|prompt)\s*["']/) {
					$needs_help = 1;
					next;
				}
				if ($f =~ /^\+\s*help\s*$/) {
					$has_help = 1;
					next;
				$f =~ s/^.//;	# strip patch context [+ ]
				$f =~ s/#.*//;	# strip # directives
				$f =~ s/^\s+//;	# strip leading blanks
				next if ($f =~ /^$/);	# skip blank lines

				# At the end of this Kconfig block:
				# This only checks context lines in the patch
				# and so hopefully shouldn't trigger false
				# positives, even though some of these are
				# common words in help texts
				if ($f =~ /^(?:config|menuconfig|choice|endchoice|
					       if|endif|menu|endmenu|source)\b/x) {
				$help_length++ if ($has_help);
			if ($needs_help &&
			    $help_length < $min_conf_desc_length) {
				my $stat_real = get_stat_real($linenr, $ln - 1);
				     "please write a help paragraph that fully describes the config symbol\n" . "$here\n$stat_real\n");
# check MAINTAINERS entries
		if ($realfile =~ /^MAINTAINERS$/) {
# check MAINTAINERS entries for the right form
			if ($rawline =~ /^\+[A-Z]:/ &&
			    $rawline !~ /^\+[A-Z]:\t\S/) {
				if (WARN("MAINTAINERS_STYLE",
					 "MAINTAINERS entries use one tab after TYPE:\n" . $herecurr) &&
				    $fix) {
					$fixed[$fixlinenr] =~ s/^(\+[A-Z]):\s*/$1:\t/;
				}
			}
# check MAINTAINERS entries for the right ordering too
			my $preferred_order = 'MRLSWQBCPTFXNK';
			if ($rawline =~ /^\+[A-Z]:/ &&
			    $prevrawline =~ /^[\+ ][A-Z]:/) {
				$rawline =~ /^\+([A-Z]):\s*(.*)/;
				my $cur = $1;
				my $curval = $2;
				$prevrawline =~ /^[\+ ]([A-Z]):\s*(.*)/;
				my $prev = $1;
				my $prevval = $2;
				my $curindex = index($preferred_order, $cur);
				my $previndex = index($preferred_order, $prev);
				if ($curindex < 0) {
					WARN("MAINTAINERS_STYLE",
					     "Unknown MAINTAINERS entry type: '$cur'\n" . $herecurr);
				} else {
					if ($previndex >= 0 && $curindex < $previndex) {
						WARN("MAINTAINERS_STYLE",
						     "Misordered MAINTAINERS entry - list '$cur:' before '$prev:'\n" . $hereprev);
					} elsif ((($prev eq 'F' && $cur eq 'F') ||
						  ($prev eq 'X' && $cur eq 'X')) &&
						 ($prevval cmp $curval) > 0) {
						WARN("MAINTAINERS_STYLE",
						     "Misordered MAINTAINERS entry - list file patterns in alphabetic order\n" . $hereprev);
					}
				}
			}
			my $vp_file = $dt_path . "vendor-prefixes.yaml";
				`grep -Eq "\\"\\^\Q$vendor\E,\\.\\*\\":" $vp_file`;
# check for using SPDX license tag at beginning of files
		if ($realline == $checklicenseline) {
			if ($rawline =~ /^[ \+]\s*\#\!\s*\//) {
				$checklicenseline = 2;
			} elsif ($rawline =~ /^\+/) {
				my $comment = "";
				if ($realfile =~ /\.(h|s|S)$/) {
					$comment = '/*';
				} elsif ($realfile =~ /\.(c|dts|dtsi)$/) {
					$comment = '//';
				} elsif (($checklicenseline == 2) || $realfile =~ /\.(sh|pl|py|awk|tc|yaml)$/) {
					$comment = '#';
				} elsif ($realfile =~ /\.rst$/) {
					$comment = '..';
				}

# check SPDX comment style for .[chsS] files
				if ($realfile =~ /\.[chsS]$/ &&
				    $rawline =~ /SPDX-License-Identifier:/ &&
				    $rawline !~ m@^\+\s*\Q$comment\E\s*@) {
					WARN("SPDX_LICENSE_TAG",
					     "Improper SPDX comment style for '$realfile', please use '$comment' instead\n" . $herecurr);
				}

				if ($comment !~ /^$/ &&
				    $rawline !~ m@^\+\Q$comment\E SPDX-License-Identifier: @) {
					WARN("SPDX_LICENSE_TAG",
					     "Missing or malformed SPDX-License-Identifier tag in line $checklicenseline\n" . $herecurr);
				} elsif ($rawline =~ /(SPDX-License-Identifier: .*)/) {
					my $spdx_license = $1;
					if (!is_SPDX_License_valid($spdx_license)) {
						WARN("SPDX_LICENSE_TAG",
						     "'$spdx_license' is not supported in LICENSES/...\n" . $herecurr);
					}
					if ($realfile =~ m@^Documentation/devicetree/bindings/@ &&
					    not $spdx_license =~ /GPL-2\.0.*BSD-2-Clause/) {
						my $msg_level = \&WARN;
						$msg_level = \&CHK if ($file);
						if (&{$msg_level}("SPDX_LICENSE_TAG",

								  "DT binding documents should be licensed (GPL-2.0-only OR BSD-2-Clause)\n" . $herecurr) &&
						    $fix) {
							$fixed[$fixlinenr] =~ s/SPDX-License-Identifier: .*/SPDX-License-Identifier: (GPL-2.0-only OR BSD-2-Clause)/;
						}
					}
				}
			}
# check for embedded filenames
		if ($rawline =~ /^\+.*\Q$realfile\E/) {
			WARN("EMBEDDED_FILENAME",
			     "It's generally not useful to have the filename in the file\n" . $herecurr);
# check we are in a valid source file if not then ignore this hunk
		next if ($realfile !~ /\.(h|c|s|S|sh|dtsi|dts)$/);

# check for using SPDX-License-Identifier on the wrong line number
		if ($realline != $checklicenseline &&
		    $rawline =~ /\bSPDX-License-Identifier:/ &&
		    substr($line, @-, @+ - @-) eq "$;" x (@+ - @-)) {
			WARN("SPDX_LICENSE_TAG",
			     "Misplaced SPDX-License-Identifier tag - use line $checklicenseline instead\n" . $herecurr);
# line length limit (with some exclusions)
#
# There are a few types of lines that may extend beyond $max_line_length:
#	logging functions like pr_info that end in a string
#	lines with a single string
#	#defines that are a single string
#	lines with an RFC3986 like URL
#
# There are 3 different line length message types:
# LONG_LINE_COMMENT	a comment starts before but extends beyond $max_line_length
# LONG_LINE_STRING	a string starts before but extends beyond $max_line_length
# LONG_LINE		all other lines longer than $max_line_length
#
# if LONG_LINE is ignored, the other 2 types are also ignored
#

		if ($line =~ /^\+/ && $length > $max_line_length) {
			my $msg_type = "LONG_LINE";

			# Check the allowed long line types first

			# logging functions that end in a string that starts
			# before $max_line_length
			if ($line =~ /^\+\s*$logFunctions\s*\(\s*(?:(?:KERN_\S+\s*|[^"]*))?($String\s*(?:|,|\)\s*;)\s*)$/ &&
			    length(expand_tabs(substr($line, 1, length($line) - length($1) - 1))) <= $max_line_length) {
				$msg_type = "";

			# lines with only strings (w/ possible termination)
			# #defines with only strings
			} elsif ($line =~ /^\+\s*$String\s*(?:\s*|,|\)\s*;)\s*$/ ||
				 $line =~ /^\+\s*#\s*define\s+\w+\s+$String$/) {
				$msg_type = "";

			# More special cases
			} elsif ($line =~ /^\+.*\bEFI_GUID\s*\(/ ||
				 $line =~ /^\+\s*(?:\w+)?\s*DEFINE_PER_CPU/) {
				$msg_type = "";

			# URL ($rawline is used in case the URL is in a comment)
			} elsif ($rawline =~ /^\+.*\b[a-z][\w\.\+\-]*:\/\/\S+/i) {
				$msg_type = "";

			# Otherwise set the alternate message types

			# a comment starts before $max_line_length
			} elsif ($line =~ /($;[\s$;]*)$/ &&
				 length(expand_tabs(substr($line, 1, length($line) - length($1) - 1))) <= $max_line_length) {
				$msg_type = "LONG_LINE_COMMENT"

			# a quoted string starts before $max_line_length
			} elsif ($sline =~ /\s*($String(?:\s*(?:\\|,\s*|\)\s*;\s*))?)$/ &&
				 length(expand_tabs(substr($line, 1, length($line) - length($1) - 1))) <= $max_line_length) {
				$msg_type = "LONG_LINE_STRING"
			if ($msg_type ne "" &&
			    (show_type("LONG_LINE") || show_type($msg_type))) {
				my $msg_level = \&WARN;
				$msg_level = \&CHK if ($file);
				&{$msg_level}($msg_type,
					      "line length of $length exceeds $max_line_length columns\n" . $herecurr);
			}
			if (WARN("MISSING_EOF_NEWLINE",
			         "adding a line without newline at end of file\n" . $herecurr) &&
			    $fix) {
				fix_delete_line($fixlinenr+1, "No newline at end of file");
			}
# check for .L prefix local symbols in .S files
		if ($realfile =~ /\.S$/ &&
		    $line =~ /^\+\s*(?:[A-Z]+_)?SYM_[A-Z]+_(?:START|END)(?:_[A-Z_]+)?\s*\(\s*\.L/) {
			WARN("AVOID_L_PREFIX",
			     "Avoid using '.L' prefixed local symbol names for denoting a range of code via 'SYM_*_START/END' annotations; see Documentation/asm-annotations.rst\n" . $herecurr);
# more than $tabsize must use tabs.
					   s/(^\+.*) {$tabsize,$tabsize}\t/$1\t\t/) {}
# check for assignments on the start of a line
		if ($sline =~ /^\+\s+($Assignment)[^=]/) {
			my $operator = $1;
			if (CHK("ASSIGNMENT_CONTINUATIONS",
				"Assignment operator '$1' should be on the previous line\n" . $hereprev) &&
			    $fix && $prevrawline =~ /^\+/) {
				# add assignment operator to the previous line, remove from current line
				$fixed[$fixlinenr - 1] .= " $operator";
				$fixed[$fixlinenr] =~ s/\Q$operator\E\s*//;
			}
		}

			my $operator = $1;
			if (CHK("LOGICAL_CONTINUATIONS",
				"Logical continuations should be on the previous line\n" . $hereprev) &&
			    $fix && $prevrawline =~ /^\+/) {
				# insert logical operator at last non-comment, non-whitepsace char on previous line
				$prevline =~ /[\s$;]*$/;
				my $line_end = substr($prevrawline, $-[0]);
				$fixed[$fixlinenr - 1] =~ s/\Q$line_end\E$/ $operator$line_end/;
				$fixed[$fixlinenr] =~ s/\Q$operator\E\s*//;
			}
		}

# check indentation starts on a tab stop
		if ($perl_version_ok &&
		    $sline =~ /^\+\t+( +)(?:$c90_Keywords\b|\{\s*$|\}\s*(?:else\b|while\b|\s*$)|$Declare\s*$Ident\s*[;=])/) {
			my $indent = length($1);
			if ($indent % $tabsize) {
				if (WARN("TABSTOP",
					 "Statements should start on a tabstop\n" . $herecurr) &&
				    $fix) {
					$fixed[$fixlinenr] =~ s@(^\+\t+) +@$1 . "\t" x ($indent/$tabsize)@e;
				}
			}
		if ($perl_version_ok &&
		    $prevline =~ /^\+([ \t]*)((?:$c90_Keywords(?:\s+if)\s*)|(?:$Declare\s*)?(?:$Ident|\(\s*\*\s*$Ident\s*\))\s*|(?:\*\s*)*$Lval\s*=\s*$Ident\s*)\(.*(\&\&|\|\||,)\s*$/) {
					"\t" x ($pos / $tabsize) .
					" "  x ($pos % $tabsize);
# check for space after cast like "(int) foo" or "(struct foo) bar"
# avoid checking a few false positives:
#   "sizeof(<type>)" or "__alignof__(<type>)"
#   function pointer declarations like "(*foo)(int) = bar;"
#   structure definitions like "(struct foo) { 0 };"
#   multiline macros that define functions
#   known attributes or the __attribute__ keyword
		if ($line =~ /^\+(.*)\(\s*$Type\s*\)([ \t]++)((?![={]|\\$|$Attribute|__attribute__))/ &&
		    (!defined($1) || $1 !~ /\b(?:sizeof|__alignof__)\s*$/)) {
# Block comment styles
# Networking with an initial /*
		    $realline > 3) { # Do not warn about the initial copyright comment block after SPDX-License-Identifier
# Block comments use * on subsequent lines
		if ($prevline =~ /$;[ \t]*$/ &&			#ends in comment
		    $prevrawline =~ /^\+.*?\/\*/ &&		#starting /*
			WARN("BLOCK_COMMENT_STYLE",
			     "Block comments use * on subsequent lines\n" . $hereprev);
# Block comments use */ on trailing lines
		if ($rawline !~ m@^\+[ \t]*\*/[ \t]*$@ &&	#trailing */
			WARN("BLOCK_COMMENT_STYLE",
			     "Block comments use a trailing */ on a separate line\n" . $herecurr);
		}

# Block comment * alignment
		if ($prevline =~ /$;[ \t]*$/ &&			#ends in comment
		    $line =~ /^\+[ \t]*$;/ &&			#leading comment
		    $rawline =~ /^\+[ \t]*\*/ &&		#leading *
		    (($prevrawline =~ /^\+.*?\/\*/ &&		#leading /*
		      $prevrawline !~ /\*\/[ \t]*$/) ||		#no trailing */
		     $prevrawline =~ /^\+[ \t]*\*/)) {		#leading *
			my $oldindent;
			$prevrawline =~ m@^\+([ \t]*/?)\*@;
			if (defined($1)) {
				$oldindent = expand_tabs($1);
			} else {
				$prevrawline =~ m@^\+(.*/?)\*@;
				$oldindent = expand_tabs($1);
			}
			$rawline =~ m@^\+([ \t]*)\*@;
			my $newindent = $1;
			$newindent = expand_tabs($newindent);
			if (length($oldindent) ne length($newindent)) {
				WARN("BLOCK_COMMENT_STYLE",
				     "Block comments should align the * on each line\n" . $hereprev);
			}
		      $line =~ /^\+\s*(?:EXPORT_SYMBOL|early_param)/ ||
		      $line =~ /^\+\s*builtin_[\w_]*driver/ ||
# (declarations must have the same indentation and not be at the start of line)
		if (($prevline =~ /\+(\s+)\S/) && $sline =~ /^\+$1\S/) {
			# use temporaries
			my $sl = $sline;
			my $pl = $prevline;
			# remove $Attribute/$Sparse uses to simplify comparisons
			$sl =~ s/\b(?:$Attribute|$Sparse)\b//g;
			$pl =~ s/\b(?:$Attribute|$Sparse)\b//g;
			if (($pl =~ /^\+\s+$Declare\s*$Ident\s*[=,;:\[]/ ||
			     $pl =~ /^\+\s+$Declare\s*\(\s*\*\s*$Ident\s*\)\s*[=,;:\[\(]/ ||
			     $pl =~ /^\+\s+$Ident(?:\s+|\s*\*\s*)$Ident\s*[=,;\[]/ ||
			     $pl =~ /^\+\s+$declaration_macros/) &&
			    !($pl =~ /^\+\s+$c90_Keywords\b/ ||
			      $pl =~ /(?:$Compare|$Assignment|$Operators)\s*$/ ||
			      $pl =~ /(?:\{\s*|\\)$/) &&
			    !($sl =~ /^\+\s+$Declare\s*$Ident\s*[=,;:\[]/ ||
			      $sl =~ /^\+\s+$Declare\s*\(\s*\*\s*$Ident\s*\)\s*[=,;:\[\(]/ ||
			      $sl =~ /^\+\s+$Ident(?:\s+|\s*\*\s*)$Ident\s*[=,;\[]/ ||
			      $sl =~ /^\+\s+$declaration_macros/ ||
			      $sl =~ /^\+\s+(?:static\s+)?(?:const\s+)?(?:union|struct|enum|typedef)\b/ ||
			      $sl =~ /^\+\s+(?:$|[\{\}\.\#\"\?\:\(\[])/ ||
			      $sl =~ /^\+\s+$Ident\s*:\s*\d+\s*[,;]/ ||
			      $sl =~ /^\+\s+\(?\s*(?:$Compare|$Assignment|$Operators)/)) {
				if (WARN("LINE_SPACING",
					 "Missing a blank line after declarations\n" . $hereprev) &&
				    $fix) {
					fix_insert_line($fixlinenr, "\+");
				}
# check for unusual line ending [ or (
		if ($line =~ /^\+.*([\[\(])\s*$/) {
			CHK("OPEN_ENDED_LINE",
			    "Lines should not end with a '$1'\n" . $herecurr);
		}

# check if this appears to be the start function declaration, save the name
		if ($sline =~ /^\+\{\s*$/ &&
		    $prevline =~ /^\+(?:(?:(?:$Storage|$Inline)\s*)*\s*$Type\s*)?($Ident)\(/) {
			$context_function = $1;
		}

# check if this appears to be the end of function declaration
		if ($sline =~ /^\+\}\s*$/) {
			undef $context_function;
		}

# if the previous line is a goto, return or break
# and is indented the same # of tabs
			if ($prevline =~ /^\+$tabs(goto|return|break)\b/) {
				if (WARN("UNNECESSARY_BREAK",
					 "break is not useful after a $1\n" . $hereprev) &&
				    $fix) {
					fix_delete_line($fixlinenr, $rawline);
				}
		if ($linenr > $suppress_statement &&
		if ($line =~ /\b(?:(?:if|while|for|(?:[a-z_]+|)for_each[a-z_]+)\s*\(|(?:do|else)\b)/ && $line !~ /^.\s*#/ && $line !~ /\}\s*while\s*/) {
			# remove inline comments
			$s =~ s/$;/ /g;
			$c =~ s/$;/ /g;
			# Make sure we remove the line prefixes as we have
			# none on the first line, and are going to readd them
			# where necessary.
			$s =~ s/\n./\n/gs;
			while ($s =~ /\n\s+\\\n/) {
				$cond_lines += $s =~ s/\n\s+\\\n/\n/g;
			}

			if ($check && $s ne '' &&
			    (($sindent % $tabsize) != 0 ||
			     ($sindent < $indent) ||
			     ($sindent == $indent &&
			      ($s !~ /^\s*(?:\}|\{|else\b)/)) ||
			     ($sindent > $indent + $tabsize))) {
# check for self assignments used to avoid compiler warnings
# e.g.:	int foo = foo, *bar = NULL;
#	struct foo bar = *(&(bar));
		if ($line =~ /^\+\s*(?:$Declare)?([A-Za-z_][A-Za-z\d_]*)\s*=/) {
			my $var = $1;
			if ($line =~ /^\+\s*(?:$Declare)?$var\s*=\s*(?:$var|\*\s*\(?\s*&\s*\(?\s*$var\s*\)?\s*\)?)\s*[;,]/) {
				WARN("SELF_ASSIGNMENT",
				     "Do not use self-assignments to avoid compiler warnings\n" . $herecurr);
			}
		}

# check for dereferences that span multiple lines
		if ($prevline =~ /^\+.*$Lval\s*(?:\.|->)\s*$/ &&
		    $line =~ /^\+\s*(?!\#\s*(?!define\s+|if))\s*$Lval/) {
			$prevline =~ /($Lval\s*(?:\.|->))\s*$/;
			my $ref = $1;
			$line =~ /^.\s*($Lval)/;
			$ref .= $1;
			$ref =~ s/\s//g;
			WARN("MULTILINE_DEREFERENCE",
			     "Avoid multiple line dereference - prefer '$ref'\n" . $hereprev);
		}

# check for declarations of signed or unsigned without int
		while ($line =~ m{\b($Declare)\s*(?!char\b|short\b|int\b|long\b)\s*($Ident)?\s*[=,;\[\)\(]}g) {
			my $type = $1;
			my $var = $2;
			$var = "" if (!defined $var);
			if ($type =~ /^(?:(?:$Storage|$Inline|$Attribute)\s+)*((?:un)?signed)((?:\s*\*)*)\s*$/) {
				my $sign = $1;
				my $pointer = $2;

				$pointer = "" if (!defined $pointer);

				if (WARN("UNSPECIFIED_INT",
					 "Prefer '" . trim($sign) . " int" . rtrim($pointer) . "' to bare use of '$sign" . rtrim($pointer) . "'\n" . $herecurr) &&
				    $fix) {
					my $decl = trim($sign) . " int ";
					my $comp_pointer = $pointer;
					$comp_pointer =~ s/\s//g;
					$decl .= $comp_pointer;
					$decl = rtrim($decl) if ($var eq "");
					$fixed[$fixlinenr] =~ s@\b$sign\s*\Q$pointer\E\s*$var\b@$decl$var@;
				}
			}
		}

				$fixedline =~ s/^(.\s*)\{\s*/$1/;
		    ($lines[$realline_next - 1] =~ /EXPORT_SYMBOL.*\((.*)\)/)) {
			$name =~ s/^\s*($Ident).*/$1/;
		    ($line =~ /EXPORT_SYMBOL.*\((.*)\)/)) {
		if ($line =~ /^\+$Type\s*$Ident(?:\s+$Modifier)*\s*=\s*($zero_initializer)\s*;/ &&
		    !exclude_global_initialisers($realfile)) {
				  "do not initialise globals to $1\n" . $herecurr) &&
				$fixed[$fixlinenr] =~ s/(^.$Type\s*$Ident(?:\s+$Modifier)*)\s*=\s*$zero_initializer\s*;/$1;/;
		if ($line =~ /^\+.*\bstatic\s.*=\s*($zero_initializer)\s*;/) {
				  "do not initialise statics to $1\n" .
				$fixed[$fixlinenr] =~ s/(\bstatic\s.*?)\s*=\s*$zero_initializer\s*;/$1;/;
# check for unnecessary <signed> int declarations of short/long/long long
		while ($sline =~ m{\b($TypeMisordered(\s*\*)*|$C90_int_types)\b}g) {
			my $type = trim($1);
			next if ($type !~ /\bint\b/);
			next if ($type !~ /\b(?:short|long\s+long|long)\b/);
			my $new_type = $type;
			$new_type =~ s/\b\s*int\s*\b/ /;
			$new_type =~ s/\b\s*(?:un)?signed\b\s*/ /;
			$new_type =~ s/^const\s+//;
			$new_type = "unsigned $new_type" if ($type =~ /\bunsigned\b/);
			$new_type = "const $new_type" if ($type =~ /^const\b/);
			$new_type =~ s/\s+/ /g;
			$new_type = trim($new_type);
			if (WARN("UNNECESSARY_INT",
				 "Prefer '$new_type' over '$type' as the int is unnecessary\n" . $herecurr) &&
			    $fix) {
				$fixed[$fixlinenr] =~ s/\b\Q$type\E\b/$new_type/;
			}
		}

		}

# check for initialized const char arrays that should be static const
		if ($line =~ /^\+\s*const\s+(char|unsigned\s+char|_*u8|(?:[us]_)?int8_t)\s+\w+\s*\[\s*(?:\w+\s*)?\]\s*=\s*"/) {
			if (WARN("STATIC_CONST_CHAR_ARRAY",
				 "const array should probably be static const\n" . $herecurr) &&
			    $fix) {
				$fixed[$fixlinenr] =~ s/(^.\s*)const\b/${1}static const/;
			}
		}
		}

# check for const <foo> const where <foo> is not a pointer or array type
		if ($sline =~ /\bconst\s+($BasicType)\s+const\b/) {
			my $found = $1;
			if ($sline =~ /\bconst\s+\Q$found\E\s+const\b\s*\*/) {
				WARN("CONST_CONST",
				     "'const $found const *' should probably be 'const $found * const'\n" . $herecurr);
			} elsif ($sline !~ /\bconst\s+\Q$found\E\s+const\s+\w+\s*\[/) {
				WARN("CONST_CONST",
				     "'const $found const' should probably be 'const $found'\n" . $herecurr);
			}
		}

# check for const static or static <non ptr type> const declarations
# prefer 'static const <foo>' over 'const static <foo>' and 'static <foo> const'
		if ($sline =~ /^\+\s*const\s+static\s+($Type)\b/ ||
		    $sline =~ /^\+\s*static\s+($BasicType)\s+const\b/) {
			if (WARN("STATIC_CONST",
				 "Move const after static - use 'static const $1'\n" . $herecurr) &&
			    $fix) {
				$fixed[$fixlinenr] =~ s/\bconst\s+static\b/static const/;
				$fixed[$fixlinenr] =~ s/\bstatic\s+($BasicType)\s+const\b/static const $1/;
			}
		}
		}

# check for sizeof(foo)/sizeof(foo[0]) that could be ARRAY_SIZE(foo)
		if ($line =~ m@\bsizeof\s*\(\s*($Lval)\s*\)@) {
			my $array = $1;
			if ($line =~ m@\b(sizeof\s*\(\s*\Q$array\E\s*\)\s*/\s*sizeof\s*\(\s*\Q$array\E\s*\[\s*0\s*\]\s*\))@) {
				my $array_div = $1;
				if (WARN("ARRAY_SIZE",
					 "Prefer ARRAY_SIZE($array)\n" . $herecurr) &&
				    $fix) {
					$fixed[$fixlinenr] =~ s/\Q$array_div\E/ARRAY_SIZE($array)/;
				}
			}
		}
		if ($line =~ /(\b$Type\s*$Ident)\s*\(\s*\)/) {
		    $line !~ /\b__bitwise\b/) {
# avoid BUG() or BUG_ON()
		if ($line =~ /\b(?:BUG|BUG_ON)\b/) {
			my $msg_level = \&WARN;
			$msg_level = \&CHK if ($file);
			&{$msg_level}("AVOID_BUG",
				      "Avoid crashing the kernel - try using WARN_ON & recovery code rather than BUG() or BUG_ON()\n" . $herecurr);
		}
# avoid LINUX_VERSION_CODE
			     "Prefer printk_ratelimited or pr_<level>_ratelimited to printk_ratelimit\n" . $herecurr);
# printk should use KERN_* levels
		if ($line =~ /\bprintk\s*\(\s*(?!KERN_[A-Z]+\b)/) {
			WARN("PRINTK_WITHOUT_KERN_LEVEL",
			     "printk() should include KERN_<LEVEL> facility level\n" . $herecurr);
# prefer variants of (subsystem|netdev|dev|pr)_<level> to printk(KERN_<LEVEL>
		if ($line =~ /\b(printk(_once|_ratelimited)?)\s*\(\s*KERN_([A-Z]+)/) {
			my $printk = $1;
			my $modifier = $2;
			my $orig = $3;
			$modifier = "" if (!defined($modifier));
			$level .= $modifier;
			$level2 .= $modifier;
			     "Prefer [subsystem eg: netdev]_$level2([subsystem]dev, ... then dev_$level2(dev, ... then pr_$level(...  to $printk(KERN_$orig ...\n" . $herecurr);
# prefer dev_<level> to dev_printk(KERN_<LEVEL>
# trace_printk should not be used in production code.
		if ($line =~ /\b(trace_printk|trace_puts|ftrace_vprintk)\s*\(/) {
			WARN("TRACE_PRINTK",
			     "Do not use $1() in production code (this can be ignored if built only with a debug config option)\n" . $herecurr);
		}

# ENOSYS means "bad syscall nr" and nothing else.  This will have a small
# number of false positives, but assembly files are not checked, so at
# least the arch entry code will not trigger this warning.
		if ($line =~ /\bENOSYS\b/) {
			WARN("ENOSYS",
			     "ENOSYS means 'invalid syscall nr' and nothing else\n" . $herecurr);
		}

# ENOTSUPP is not a standard error code and should be avoided in new patches.
# Folks usually mean EOPNOTSUPP (also called ENOTSUP), when they type ENOTSUPP.
# Similarly to ENOSYS warning a small number of false positives is expected.
		if (!$file && $line =~ /\bENOTSUPP\b/) {
			if (WARN("ENOTSUPP",
				 "ENOTSUPP is not a SUSV4 error code, prefer EOPNOTSUPP\n" . $herecurr) &&
			    $fix) {
				$fixed[$fixlinenr] =~ s/\bENOTSUPP\b/EOPNOTSUPP/;
			}
		}

		if ($perl_version_ok &&
		    $sline =~ /$Type\s*$Ident\s*$balanced_parens\s*\{/ &&
		    $sline !~ /\#\s*define\b.*do\s*\{/ &&
		    $sline !~ /}/) {
				  "open brace '{' following function definitions go on the next line\n" . $herecurr) &&
				$fixed_line =~ /(^..*$Type\s*$Ident\(.*\)\s*)\{(.*)$/;
				$fixedline =~ s/^(.\s*)\{\s*/$1\t/;
			    $prefix !~ /[{,:]\s+$/) {
				    $ca =~ /\s$/ && $cc =~ /^\s*[,\)]/) {
				# , must not have a space before and must have a space on the right.
					my $rtrim_before = 0;
					my $space_after = 0;
					if ($ctx =~ /Wx./) {
						if (ERROR("SPACING",
							  "space prohibited before that '$op' $at\n" . $hereptr)) {
							$line_fixed = 1;
							$rtrim_before = 1;
						}
					}
							$space_after = 1;
						}
					}
					if ($rtrim_before || $space_after) {
						if ($rtrim_before) {
							$good = rtrim($fix_elements[$n]) . trim($fix_elements[$n + 1]);
						} else {
							$good = $fix_elements[$n] . trim($fix_elements[$n + 1]);
						}
						if ($space_after) {
							$good .= " ";
					if ($check) {
						if (defined $fix_elements[$n + 2] && $ctx !~ /[EW]x[EW]/) {
							if (CHK("SPACING",
								"spaces preferred around that '$op' $at\n" . $hereptr)) {
								$good = rtrim($fix_elements[$n]) . " " . trim($fix_elements[$n + 1]) . " ";
								$fix_elements[$n + 2] =~ s/^\s+//;
								$line_fixed = 1;
							}
						} elsif (!defined $fix_elements[$n + 2] && $ctx !~ /Wx[OE]/) {
							if (CHK("SPACING",
								"space preferred before that '$op' $at\n" . $hereptr)) {
								$good = rtrim($fix_elements[$n]) . " " . trim($fix_elements[$n + 1]);
								$line_fixed = 1;
							}
						}
					} elsif ($ctx =~ /Wx[^WCE]|[^WCE]xW/) {
					if ($ctx =~ /Wx./ and $realfile !~ m@.*\.lds\.h$@) {
						$ok = 1;
					}

					# for asm volatile statements
					# ignore a colon with another
					# colon immediately before or after
					if (($op eq ':') &&
					    ($ca =~ /:$/ || $cc =~ /^:/)) {
						$ok = 1;
						my $msg_level = \&ERROR;
						$msg_level = \&CHK if (($op eq '?:' || $op eq '?' || $op eq ':') && $ctx =~ /VxV/);
						if (&{$msg_level}("SPACING",
								  "spaces required around that '$op' $at\n" . $hereptr)) {
## 			# falsely report the parameters of functions.
		if (($line =~ /\(.*\)\{/ && $line !~ /\($Type\)\{/) ||
		    $line =~ /\b(?:else|do)\{/) {
				$fixed[$fixlinenr] =~ s/^(\+.*(?:do|else|\)))\{/$1 {/;
		if ($line =~ /}(?!(?:,|;|\)|\}))\S/) {
			my $var = $1;
			if (CHK("UNNECESSARY_PARENTHESES",
				"Unnecessary parentheses around $var\n" . $herecurr) &&
			    $fix) {
				$fixed[$fixlinenr] =~ s/\(\s*\Q$var\E\s*\)/$var/;
			}
		}
# check for unnecessary parentheses around function pointer uses
# ie: (foo->bar)(); should be foo->bar();
# but not "if (foo->bar) (" to avoid some false positives
		if ($line =~ /(\bif\s*|)(\(\s*$Ident\s*(?:$Member\s*)+\))[ \t]*\(/ && $1 !~ /^if/) {
			my $var = $2;
			if (CHK("UNNECESSARY_PARENTHESES",
				"Unnecessary parentheses around function pointer $var\n" . $herecurr) &&
			    $fix) {
				my $var2 = deparenthesize($var);
				$var2 =~ s/\s//g;
				$fixed[$fixlinenr] =~ s/\Q$var\E/$var2/;
			}
		}

# check for unnecessary parentheses around comparisons in if uses
# when !drivers/staging or command-line uses --strict
		if (($realfile !~ m@^(?:drivers/staging/)@ || $check_orig) &&
		    $perl_version_ok && defined($stat) &&
		    $stat =~ /(^.\s*if\s*($balanced_parens))/) {
			my $if_stat = $1;
			my $test = substr($2, 1, -1);
			my $herectx;
			while ($test =~ /(?:^|[^\w\&\!\~])+\s*\(\s*([\&\!\~]?\s*$Lval\s*(?:$Compare\s*$FuncArg)?)\s*\)/g) {
				my $match = $1;
				# avoid parentheses around potential macro args
				next if ($match =~ /^\s*\w+\s*$/);
				if (!defined($herectx)) {
					$herectx = $here . "\n";
					my $cnt = statement_rawlines($if_stat);
					for (my $n = 0; $n < $cnt; $n++) {
						my $rl = raw_line($linenr, $n);
						$herectx .=  $rl . "\n";
						last if $rl =~ /^[ \+].*\{/;
					}
				}
				CHK("UNNECESSARY_PARENTHESES",
				    "Unnecessary parentheses around '$match'\n" . $herectx);
			}
		}

# check that goto labels aren't indented (allow a single space indentation)
# and ignore bitfield definitions like foo:1
# Strictly, labels can have whitespace after the identifier and before the :
# but this is not allowed here as many ?: uses would appear to be labels
		if ($sline =~ /^.\s+[A-Za-z_][A-Za-z\d_]*:(?!\s*\d+)/ &&
		    $sline !~ /^. [A-Za-z\d_][A-Za-z\d_]*:/ &&
		    $sline !~ /^.\s+default:/) {
# check if a statement with a comma should be two statements like:
#	foo = bar(),	/* comma should be semicolon */
#	bar = baz();
		if (defined($stat) &&
		    $stat =~ /^\+\s*(?:$Lval\s*$Assignment\s*)?$FuncArg\s*,\s*(?:$Lval\s*$Assignment\s*)?$FuncArg\s*;\s*$/) {
			my $cnt = statement_rawlines($stat);
			my $herectx = get_stat_here($linenr, $cnt, $here);
			WARN("SUSPECT_COMMA_SEMICOLON",
			     "Possible comma where semicolon could be used\n" . $herectx);
		}

			if ($perl_version_ok &&
		}
		if ($perl_version_ok &&
# comparisons with a constant or upper case identifier on the left
#	avoid cases like "foo + BAR < baz"
#	only fix matches surrounded by parentheses to avoid incorrect
#	conversions like "FOO < baz() + 5" being "misfixed" to "baz() > FOO + 5"
		if ($perl_version_ok &&
		    $line =~ /^\+(.*)\b($Constant|[A-Z_][A-Z0-9_]*)\s*($Compare)\s*($LvalOrFunc)/) {
			my $lead = $1;
			my $const = $2;
			my $comp = $3;
			my $to = $4;
			my $newcomp = $comp;
			if ($lead !~ /(?:$Operators|\.)\s*$/ &&
			    $to !~ /^(?:Constant|[A-Z_][A-Z0-9_]*)$/ &&
			    WARN("CONSTANT_COMPARISON",
				 "Comparisons should place the constant on the right side of the test\n" . $herecurr) &&
			    $fix) {
				if ($comp eq "<") {
					$newcomp = ">";
				} elsif ($comp eq "<=") {
					$newcomp = ">=";
				} elsif ($comp eq ">") {
					$newcomp = "<";
				} elsif ($comp eq ">=") {
					$newcomp = "<=";
				}
				$fixed[$fixlinenr] =~ s/\(\s*\Q$const\E\s*$Compare\s*\Q$to\E\s*\)/($to $newcomp $const)/;
			}
		}

# Return of what appears to be an errno should normally be negative
		if ($sline =~ /\breturn(?:\s*\(+\s*|\s+)(E[A-Z]+)(?:\s*\)+\s*|\s*)[;:,]/) {
			if ($name ne 'EOF' && $name ne 'ERROR' && $name !~ /^EPOLL/) {
				     "return of an errno should typically be negative (ie: return -$1)\n" . $herecurr);
			my $fixed_assign_in_if = 0;
				if (ERROR("ASSIGN_IN_IF",
					  "do not use assignment in if condition\n" . $herecurr) &&
				    $fix && $perl_version_ok) {
					if ($rawline =~ /^\+(\s+)if\s*\(\s*(\!)?\s*\(\s*(($Lval)\s*=\s*$LvalOrFunc)\s*\)\s*(?:($Compare)\s*($FuncArg))?\s*\)\s*(\{)?\s*$/) {
						my $space = $1;
						my $not = $2;
						my $statement = $3;
						my $assigned = $4;
						my $test = $8;
						my $against = $9;
						my $brace = $15;
						fix_delete_line($fixlinenr, $rawline);
						fix_insert_line($fixlinenr, "$space$statement;");
						my $newline = "${space}if (";
						$newline .= '!' if defined($not);
						$newline .= '(' if (defined $not && defined($test) && defined($against));
						$newline .= "$assigned";
						$newline .= " $test $against" if (defined($test) && defined($against));
						$newline .= ')' if (defined $not && defined($test) && defined($against));
						$newline .= ')';
						$newline .= " {" if (defined($brace));
						fix_insert_line($fixlinenr + 1, $newline);
						$fixed_assign_in_if = 1;
					}
				}
			$s =~ s/$;//g;	# Remove any comments
				if (ERROR("TRAILING_STATEMENTS",
					  "trailing statements should be on next line\n" . $herecurr . $stat_real) &&
				    !$fixed_assign_in_if &&
				    $cond_lines == 0 &&
				    $fix && $perl_version_ok &&
				    $fixed[$fixlinenr] =~ /^\+(\s*)((?:if|while|for)\s*$balanced_parens)\s*(.*)$/) {
					my $indent = $1;
					my $test = $2;
					my $rest = rtrim($4);
					if ($rest =~ /;$/) {
						$fixed[$fixlinenr] = "\+$indent$test";
						fix_insert_line($fixlinenr + 1, "$indent\t$rest");
					}
				}
			$s =~ s/$;//g;	# Remove any comments
#Ignore some autogenerated defines and enum values
			    $var !~ /^(?:[A-Z]+_){1,5}[A-Z]{1,3}[a-z]/ &&
#Ignore SI style variants like nS, mV and dB
#(ie: max_uV, regulator_min_uA_show, RANGE_mA_VALUE)
			    $var !~ /^(?:[a-z0-9_]*|[A-Z0-9_]*)?_?[a-z][A-Z](?:_[a-z0-9_]+|_[A-Z0-9_]+)?$/ &&
#Ignore some three character SI units explicitly, like MiB and KHz
			    $var !~ /^(?:[a-z_]*?)_?(?:[KMGT]iB|[KMGT]?Hz)(?:_[a-z_]+)?$/) {
# warn if <asm/foo.h> is #included and <linux/foo.h> is available and includes
# itself <asm/foo.h> (uses RAW line)
				my $asminclude = `grep -Ec "#include\\s+<asm/$file>" $root/$checkfile`;
				if ($asminclude > 0) {
					if ($realfile =~ m{^arch/}) {
						CHK("ARCH_INCLUDE_LINUX",
						    "Consider using #include <linux/$file> instead of <asm/$file>\n" . $herecurr);
					} else {
						WARN("INCLUDE_LINUX",
						     "Use #include <linux/$file> instead of <asm/$file>\n" . $herecurr);
					}
			$has_arg_concat = 1 if ($ctx =~ /\#\#/ && $ctx !~ /\#\#\s*(?:__VA_ARGS__|args)\b/);

			$dstat =~ s/^.\s*\#\s*define\s+$Ident(\([^\)]*\))?\s*//;
			my $define_args = $1;
			my $define_stmt = $dstat;
			my @def_args = ();

			if (defined $define_args && $define_args ne "") {
				$define_args = substr($define_args, 1, length($define_args) - 2);
				$define_args =~ s/\s*//g;
				$define_args =~ s/\\\+?//g;
				@def_args = split(",", $define_args);
			}
			while ($dstat =~ s/\([^\(\)]*\)/1u/ ||
			       $dstat =~ s/\{[^\{\}]*\}/1u/ ||
			       $dstat =~ s/.\[[^\[\]]*\]/1u/)
			# Flatten any obvious string concatenation.
			while ($dstat =~ s/($String)\s*$Ident/$1/ ||
			       $dstat =~ s/$Ident\s*($String)/$1/)
			# Make asm volatile uses seem like a generic function
			$dstat =~ s/\b_*asm_*\s+_*volatile_*\b/asm_volatile/g;

				^\"|\"$|
				^\[

			$ctx =~ s/\n*$//;
			my $stmt_cnt = statement_rawlines($ctx);
			my $herectx = get_stat_here($linenr, $stmt_cnt, $here);

			    $dstat !~ /^while\s*$Constant\s*$Constant\s*$/ &&		# while (...) {...}
			    $dstat !~ /^\(\{/ &&						# ({...
				if ($dstat =~ /^\s*if\b/) {
					ERROR("MULTISTATEMENT_MACRO_USE_DO_WHILE",
					      "Macros starting with if should be enclosed by a do - while loop to avoid possible if/else logic defects\n" . "$herectx");
				} elsif ($dstat =~ /;/) {

			}

			# Make $define_stmt single line, comment-free, etc
			my @stmt_array = split('\n', $define_stmt);
			my $first = 1;
			$define_stmt = "";
			foreach my $l (@stmt_array) {
				$l =~ s/\\$//;
				if ($first) {
					$define_stmt = $l;
					$first = 0;
				} elsif ($l =~ /^[\+ ]/) {
					$define_stmt .= substr($l, 1);
				}
			}
			$define_stmt =~ s/$;//g;
			$define_stmt =~ s/\s+/ /g;
			$define_stmt = trim($define_stmt);

# check if any macro arguments are reused (ignore '...' and 'type')
			foreach my $arg (@def_args) {
			        next if ($arg =~ /\.\.\./);
			        next if ($arg =~ /^type$/i);
				my $tmp_stmt = $define_stmt;
				$tmp_stmt =~ s/\b(__must_be_array|offsetof|sizeof|sizeof_field|__stringify|typeof|__typeof__|__builtin\w+|typecheck\s*\(\s*$Type\s*,|\#+)\s*\(*\s*$arg\s*\)*\b//g;
				$tmp_stmt =~ s/\#+\s*$arg\b//g;
				$tmp_stmt =~ s/\b$arg\s*\#\#//g;
				my $use_cnt = () = $tmp_stmt =~ /\b$arg\b/g;
				if ($use_cnt > 1) {
					CHK("MACRO_ARG_REUSE",
					    "Macro argument reuse '$arg' - possible side-effects?\n" . "$herectx");
				    }
# check if any macro arguments may have other precedence issues
				if ($tmp_stmt =~ m/($Operators)?\s*\b$arg\b\s*($Operators)?/m &&
				    ((defined($1) && $1 ne ',') ||
				     (defined($2) && $2 ne ','))) {
					CHK("MACRO_ARG_PRECEDENCE",
					    "Macro argument '$arg' may be better as '($arg)' to avoid precedence issues\n" . "$herectx");
				}
				my $herectx = get_stat_here($linenr, $cnt, $here);
		if ($perl_version_ok &&
			$dstat =~ s/$;/ /g;
				my $herectx = get_stat_here($linenr, $cnt, $here);
				my $herectx = get_stat_here($linenr, $cnt, $here);
				my $herectx = get_stat_here($linenr, $cnt, $here);
# check for single line unbalanced braces
		if ($sline =~ /^.\s*\}\s*else\s*$/ ||
		    $sline =~ /^.\s*else\s*\{\s*$/) {
			CHK("BRACES", "Unbalanced braces around else statement\n" . $herecurr);
		}

			if (CHK("BRACES",
				"Blank lines aren't necessary before a close brace '}'\n" . $hereprev) &&
			    $fix && $prevrawline =~ /^\+/) {
				fix_delete_line($fixlinenr - 1, $prevrawline);
			}
			if (CHK("BRACES",
				"Blank lines aren't necessary after an open brace '{'\n" . $hereprev) &&
			    $fix) {
				fix_delete_line($fixlinenr, $rawline);
			}
			     "Use of volatile is usually wrong: see Documentation/process/volatile-considered-harmful.rst\n" . $herecurr);
		}

# Check for user-visible strings broken across lines, which breaks the ability
# to grep for the string.  Make exceptions when the previous string ends in a
# newline (multiple lines in one string constant) or '\t', '\r', ';', or '{'
# (common in inline assembly) or is a octal \123 or hexadecimal \xaf value
		if ($line =~ /^\+\s*$String/ &&
		    $prevline =~ /"\s*$/ &&
		    $prevrawline !~ /(?:\\(?:[ntr]|[0-7]{1,3}|x[0-9a-fA-F]{1,2})|;\s*|\{\s*)"\s*$/) {
			if (WARN("SPLIT_STRING",
				 "quoted string split across lines\n" . $hereprev) &&
				     $fix &&
				     $prevrawline =~ /^\+.*"\s*$/ &&
				     $last_coalesced_string_linenr != $linenr - 1) {
				my $extracted_string = get_quoted_string($line, $rawline);
				my $comma_close = "";
				if ($rawline =~ /\Q$extracted_string\E(\s*\)\s*;\s*$|\s*,\s*)/) {
					$comma_close = $1;
				}

				fix_delete_line($fixlinenr - 1, $prevrawline);
				fix_delete_line($fixlinenr, $rawline);
				my $fixedline = $prevrawline;
				$fixedline =~ s/"\s*$//;
				$fixedline .= substr($extracted_string, 1) . trim($comma_close);
				fix_insert_line($fixlinenr - 1, $fixedline);
				$fixedline = $rawline;
				$fixedline =~ s/\Q$extracted_string\E\Q$comma_close\E//;
				if ($fixedline !~ /\+\s*$/) {
					fix_insert_line($fixlinenr, $fixedline);
				}
				$last_coalesced_string_linenr = $linenr;
			}
		}

# check for missing a space in a string concatenation
		if ($prevrawline =~ /[^\\]\w"$/ && $rawline =~ /^\+[\t ]+"\w/) {
			WARN('MISSING_SPACE',
			     "break quoted strings at a space character\n" . $hereprev);
		}

# check for an embedded function name in a string when the function is known
# This does not work very well for -f --file checking as it depends on patch
# context providing the function name or a single line form for in-file
# function declarations
		if ($line =~ /^\+.*$String/ &&
		    defined($context_function) &&
		    get_quoted_string($line, $rawline) =~ /\b$context_function\b/ &&
		    length(get_quoted_string($line, $rawline)) != (length($context_function) + 2)) {
			WARN("EMBEDDED_FUNCTION_NAME",
			     "Prefer using '\"%s...\", __func__' to using '$context_function', this function's name, in a string\n" . $herecurr);
		}

# check for unnecessary function tracing like uses
# This does not use $logFunctions because there are many instances like
# 'dprintk(FOO, "%s()\n", __func__);' which do not match $logFunctions
		if ($rawline =~ /^\+.*\([^"]*"$tracing_logging_tags{0,3}%s(?:\s*\(\s*\)\s*)?$tracing_logging_tags{0,3}(?:\\n)?"\s*,\s*__func__\s*\)\s*;/) {
			if (WARN("TRACING_LOGGING",
				 "Unnecessary ftrace-like logging - prefer using ftrace\n" . $herecurr) &&
			    $fix) {
                                fix_delete_line($fixlinenr, $rawline);
			}
		}

# check for spaces before a quoted newline
		if ($rawline =~ /^.*\".*\s\\n/) {
			if (WARN("QUOTED_WHITESPACE_BEFORE_NEWLINE",
				 "unnecessary whitespace before a quoted newline\n" . $herecurr) &&
			    $fix) {
				$fixed[$fixlinenr] =~ s/^(\+.*\".*)\s+\\n/$1\\n/;
			}

		if ($line =~ /$String[A-Z_]/ ||
		    ($line =~ /([A-Za-z0-9_]+)$String/ && $1 !~ /^[Lu]$/)) {
			if (CHK("CONCATENATED_STRING",
				"Concatenated strings should use spaces between elements\n" . $herecurr) &&
			    $fix) {
				while ($line =~ /($String)/g) {
					my $extracted_string = substr($rawline, $-[0], $+[0] - $-[0]);
					$fixed[$fixlinenr] =~ s/\Q$extracted_string\E([A-Za-z0-9_])/$extracted_string $1/;
					$fixed[$fixlinenr] =~ s/([A-Za-z0-9_])\Q$extracted_string\E/$1 $extracted_string/;
				}
			}
		}

# uncoalesced string fragments
		if ($line =~ /$String\s*[Lu]?"/) {
			if (WARN("STRING_FRAGMENTS",
				 "Consecutive strings are generally better as a single string\n" . $herecurr) &&
			    $fix) {
				while ($line =~ /($String)(?=\s*")/g) {
					my $extracted_string = substr($rawline, $-[0], $+[0] - $-[0]);
					$fixed[$fixlinenr] =~ s/\Q$extracted_string\E\s*"/substr($extracted_string, 0, -1)/e;
				}
			}
		}

# check for non-standard and hex prefixed decimal printf formats
		my $show_L = 1;	#don't show the same defect twice
		my $show_Z = 1;
		while ($line =~ /(?:^|")([X\t]*)(?:"|$)/g) {
			my $string = substr($rawline, $-[1], $+[1] - $-[1]);
			$string =~ s/%%/__/g;
			# check for %L
			if ($show_L && $string =~ /%[\*\d\.\$]*L([diouxX])/) {
				WARN("PRINTF_L",
				     "\%L$1 is non-standard C, use %ll$1\n" . $herecurr);
				$show_L = 0;
			}
			# check for %Z
			if ($show_Z && $string =~ /%[\*\d\.\$]*Z([diouxX])/) {
				WARN("PRINTF_Z",
				     "%Z$1 is non-standard C, use %z$1\n" . $herecurr);
				$show_Z = 0;
			}
			# check for 0x<decimal>
			if ($string =~ /0x%[\*\d\.\$\Llzth]*[diou]/) {
				ERROR("PRINTF_0XDECIMAL",
				      "Prefixing 0x with decimal output is defective\n" . $herecurr);
			}
		}

# check for line continuations in quoted strings with odd counts of "
		if ($rawline =~ /\\$/ && $sline =~ tr/"/"/ % 2) {
			WARN("LINE_CONTINUATIONS",
			     "Avoid line continuations in quoted strings\n" . $herecurr);
			WARN("IF_0",
			     "Consider removing the code enclosed by this #if 0 and its #endif\n" . $herecurr);
		}

# warn about #if 1
		if ($line =~ /^.\s*\#\s*if\s+1\b/) {
			WARN("IF_1",
			     "Consider removing the #if 1 and its #endif\n" . $herecurr);
			my $tested = quotemeta($1);
			my $expr = '\s*\(\s*' . $tested . '\s*\)\s*;';
			if ($line =~ /\b(kfree|usb_free_urb|debugfs_remove(?:_recursive)?|(?:kmem_cache|mempool|dma_pool)_destroy)$expr/) {
				my $func = $1;
				if (WARN('NEEDLESS_IF',
					 "$func(NULL) is safe and this check is probably not required\n" . $hereprev) &&
				    $fix) {
					my $do_fix = 1;
					my $leading_tabs = "";
					my $new_leading_tabs = "";
					if ($lines[$linenr - 2] =~ /^\+(\t*)if\s*\(\s*$tested\s*\)\s*$/) {
						$leading_tabs = $1;
					} else {
						$do_fix = 0;
					}
					if ($lines[$linenr - 1] =~ /^\+(\t+)$func\s*\(\s*$tested\s*\)\s*;\s*$/) {
						$new_leading_tabs = $1;
						if (length($leading_tabs) + 1 ne length($new_leading_tabs)) {
							$do_fix = 0;
						}
					} else {
						$do_fix = 0;
					}
					if ($do_fix) {
						fix_delete_line($fixlinenr - 1, $prevrawline);
						$fixed[$fixlinenr] =~ s/^\+$new_leading_tabs/\+$leading_tabs/;
					}
				}
			if ($s =~ /(?:^|\n)[ \+]\s*(?:$Type\s*)?\Q$testval\E\s*=\s*(?:\([^\)]*\)\s*)?\s*$allocFunctions\s*\(/ &&
			    $s !~ /\b__GFP_NOWARN\b/ ) {
		if ($line !~ /printk(?:_ratelimited|_once)?\s*\(/ &&
# check for logging continuations
		if ($line =~ /\bprintk\s*\(\s*KERN_CONT\b|\bpr_cont\s*\(/) {
			WARN("LOGGING_CONTINUATION",
			     "Avoid logging continuation uses where feasible\n" . $herecurr);
		}

# check for unnecessary use of %h[xudi] and %hh[xudi] in logging functions
		if (defined $stat &&
		    $line =~ /\b$logFunctions\s*\(/ &&
		    index($stat, '"') >= 0) {
			my $lc = $stat =~ tr@\n@@;
			$lc = $lc + $linenr;
			my $stat_real = get_stat_real($linenr, $lc);
			pos($stat_real) = index($stat_real, '"');
			while ($stat_real =~ /[^\"%]*(%[\#\d\.\*\-]*(h+)[idux])/g) {
				my $pspec = $1;
				my $h = $2;
				my $lineoff = substr($stat_real, 0, $-[1]) =~ tr@\n@@;
				if (WARN("UNNECESSARY_MODIFIER",
					 "Integer promotion: Using '$h' in '$pspec' is unnecessary\n" . "$here\n$stat_real\n") &&
				    $fix && $fixed[$fixlinenr + $lineoff] =~ /^\+/) {
					my $nspec = $pspec;
					$nspec =~ s/h//g;
					$fixed[$fixlinenr + $lineoff] =~ s/\Q$pspec\E/$nspec/;
				}
			}
		}

# check for mask then right shift without a parentheses
		if ($perl_version_ok &&
		    $line =~ /$LvalOrFunc\s*\&\s*($LvalOrFunc)\s*>>/ &&
		    $4 !~ /^\&/) { # $LvalOrFunc may be &foo, ignore if so
			WARN("MASK_THEN_SHIFT",
			     "Possible precedence defect with mask then right shift - may need parentheses\n" . $herecurr);
		}

# check for pointer comparisons to NULL
		if ($perl_version_ok) {
			while ($line =~ /\b$LvalOrFunc\s*(==|\!=)\s*NULL\b/g) {
				my $val = $1;
				my $equal = "!";
				$equal = "" if ($4 eq "!=");
				if (CHK("COMPARISON_TO_NULL",
					"Comparison to NULL could be written \"${equal}${val}\"\n" . $herecurr) &&
					    $fix) {
					$fixed[$fixlinenr] =~ s/\b\Q$val\E\s*(?:==|\!=)\s*NULL\b/$equal$val/;
				}
			}
		}

# check for __read_mostly with const non-pointer (should just be const)
		if ($line =~ /\b__read_mostly\b/ &&
		    $line =~ /($Type)\s*$Ident/ && $1 !~ /\*\s*$/ && $1 =~ /\bconst\b/) {
			if (ERROR("CONST_READ_MOSTLY",
				  "Invalid use of __read_mostly with const type\n" . $herecurr) &&
			    $fix) {
				$fixed[$fixlinenr] =~ s/\s+__read_mostly\b//;
			}
		}

				    "usleep_range is preferred over udelay; see Documentation/timers/timers-howto.rst\n" . $herecurr);
				     "msleep < 20ms can sleep for up to 20ms; see Documentation/timers/timers-howto.rst\n" . $herecurr);

		my $barriers = qr{
			mb|
			rmb|
			wmb
		}x;
		my $barrier_stems = qr{
			mb__before_atomic|
			mb__after_atomic|
			store_release|
			load_acquire|
			store_mb|
			(?:$barriers)
		}x;
		my $all_barriers = qr{
			(?:$barriers)|
			smp_(?:$barrier_stems)|
			virt_(?:$barrier_stems)
		}x;

		if ($line =~ /\b(?:$all_barriers)\s*\(/) {

		my $underscore_smp_barriers = qr{__smp_(?:$barrier_stems)}x;

		if ($realfile !~ m@^include/asm-generic/@ &&
		    $realfile !~ m@/barrier\.h$@ &&
		    $line =~ m/\b(?:$underscore_smp_barriers)\s*\(/ &&
		    $line !~ m/^.\s*\#\s*define\s+(?:$underscore_smp_barriers)\s*\(/) {
			WARN("MEMORY_BARRIER",
			     "__smp memory barriers shouldn't be used outside barrier.h and asm-generic\n" . $herecurr);
		}

# check for waitqueue_active without a comment.
		if ($line =~ /\bwaitqueue_active\s*\(/) {
			if (!ctx_has_comment($first_line, $linenr)) {
				WARN("WAITQUEUE_ACTIVE",
				     "waitqueue_active without comment\n" . $herecurr);
			}
		}

# check for data_race without a comment.
		if ($line =~ /\bdata_race\s*\(/) {
			if (!ctx_has_comment($first_line, $linenr)) {
				WARN("DATA_RACE",
				     "data_race without comment\n" . $herecurr);
			}
		}

# check that the storage class is not after a type
		if ($line =~ /\b($Type)\s+($Storage)\b/) {
			WARN("STORAGE_CLASS",
			     "storage class '$2' should be located before type '$1'\n" . $herecurr);
		}
		if ($line =~ /\b$Storage\b/ &&
		    $line !~ /^.\s*$Storage/ &&
		    $line =~ /^.\s*(.+?)\$Storage\s/ &&
		    $1 !~ /[\,\)]\s*$/) {
			     "storage class should be at the beginning of the declaration\n" . $herecurr);
# Check for compiler attributes
		    $rawline =~ /\b__attribute__\s*\(\s*($balanced_parens)\s*\)/) {
			my $attr = $1;
			$attr =~ s/\s*\(\s*(.*)\)\s*/$1/;

			my %attr_list = (
				"alias"				=> "__alias",
				"aligned"			=> "__aligned",
				"always_inline"			=> "__always_inline",
				"assume_aligned"		=> "__assume_aligned",
				"cold"				=> "__cold",
				"const"				=> "__attribute_const__",
				"copy"				=> "__copy",
				"designated_init"		=> "__designated_init",
				"externally_visible"		=> "__visible",
				"format"			=> "printf|scanf",
				"gnu_inline"			=> "__gnu_inline",
				"malloc"			=> "__malloc",
				"mode"				=> "__mode",
				"no_caller_saved_registers"	=> "__no_caller_saved_registers",
				"noclone"			=> "__noclone",
				"noinline"			=> "noinline",
				"nonstring"			=> "__nonstring",
				"noreturn"			=> "__noreturn",
				"packed"			=> "__packed",
				"pure"				=> "__pure",
				"section"			=> "__section",
				"used"				=> "__used",
				"weak"				=> "__weak"
			);

			while ($attr =~ /\s*(\w+)\s*(${balanced_parens})?/g) {
				my $orig_attr = $1;
				my $params = '';
				$params = $2 if defined($2);
				my $curr_attr = $orig_attr;
				$curr_attr =~ s/^[\s_]+|[\s_]+$//g;
				if (exists($attr_list{$curr_attr})) {
					my $new = $attr_list{$curr_attr};
					if ($curr_attr eq "format" && $params) {
						$params =~ /^\s*\(\s*(\w+)\s*,\s*(.*)/;
						$new = "__$1\($2";
					} else {
						$new = "$new$params";
					}
					if (WARN("PREFER_DEFINED_ATTRIBUTE_MACRO",
						 "Prefer $new over __attribute__(($orig_attr$params))\n" . $herecurr) &&
					    $fix) {
						my $remove = "\Q$orig_attr\E" . '\s*' . "\Q$params\E" . '(?:\s*,\s*)?';
						$fixed[$fixlinenr] =~ s/$remove//;
						$fixed[$fixlinenr] =~ s/\b__attribute__/$new __attribute__/;
						$fixed[$fixlinenr] =~ s/\}\Q$new\E/} $new/;
						$fixed[$fixlinenr] =~ s/ __attribute__\s*\(\s*\(\s*\)\s*\)//;
					}
				}
			}

			# Check for __attribute__ unused, prefer __always_unused or __maybe_unused
			if ($attr =~ /^_*unused/) {
				WARN("PREFER_DEFINED_ATTRIBUTE_MACRO",
				     "__always_unused or __maybe_unused is preferred over __attribute__((__unused__))\n" . $herecurr);
			}
# Check for __attribute__ weak, or __weak declarations (may have link issues)
		if ($perl_version_ok &&
		    $line =~ /(?:$Declare|$DeclareMisordered)\s*$Ident\s*$balanced_parens\s*(?:$Attribute)?\s*;/ &&
		    ($line =~ /\b__attribute__\s*\(\s*\(.*\bweak\b/ ||
		     $line =~ /\b__weak\b/)) {
			ERROR("WEAK_DECLARATION",
			      "Using weak declarations can have unintended link defects\n" . $herecurr);
# check for c99 types like uint8_t used outside of uapi/ and tools/
		    $realfile !~ m@\btools/@ &&
		    $line =~ /\b($Declare)\s*$Ident\s*[=;,\[]/) {
			my $type = $1;
			if ($type =~ /\b($typeC99Typedefs)\b/) {
				$type = $1;
				my $kernel_type = 'u';
				$kernel_type = 's' if ($type =~ /^_*[si]/);
				$type =~ /(\d+)/;
				$kernel_type .= $1;
				if (CHK("PREFER_KERNEL_TYPES",
					"Prefer kernel type '$kernel_type' over '$type'\n" . $herecurr) &&
				    $fix) {
					$fixed[$fixlinenr] =~ s/\b$type\b/$kernel_type/;
				}
# check for cast of C90 native int or longer types constants
		if ($line =~ /(\(\s*$C90_int_types\s*\)\s*)($Constant)\b/) {
			my $cast = $1;
			my $const = $2;
			my $suffix = "";
			my $newconst = $const;
			$newconst =~ s/${Int_type}$//;
			$suffix .= 'U' if ($cast =~ /\bunsigned\b/);
			if ($cast =~ /\blong\s+long\b/) {
			    $suffix .= 'LL';
			} elsif ($cast =~ /\blong\b/) {
			    $suffix .= 'L';
			}
			if (WARN("TYPECAST_INT_CONSTANT",
				 "Unnecessary typecast of c90 int constant - '$cast$const' could be '$const$suffix'\n" . $herecurr) &&
				$fixed[$fixlinenr] =~ s/\Q$cast\E$const\b/$newconst$suffix/;
			$fmt =~ s/%%//g;
			if ($fmt !~ /%/) {
# check for vsprintf extension %p<foo> misuses
		if ($perl_version_ok &&
		    defined $stat &&
		    $stat =~ /^\+(?![^\{]*\{\s*).*\b(\w+)\s*\(.*$String\s*,/s &&
		    $1 !~ /^_*volatile_*$/) {
			my $stat_real;

			my $lc = $stat =~ tr@\n@@;
			$lc = $lc + $linenr;
		        for (my $count = $linenr; $count <= $lc; $count++) {
				my $specifier;
				my $extension;
				my $qualifier;
				my $bad_specifier = "";
				my $fmt = get_quoted_string($lines[$count - 1], raw_line($count, 0));
				$fmt =~ s/%%//g;

				while ($fmt =~ /(\%[\*\d\.]*p(\w)(\w*))/g) {
					$specifier = $1;
					$extension = $2;
					$qualifier = $3;
					if ($extension !~ /[4SsBKRraEehMmIiUDdgVCbGNOxtf]/ ||
					    ($extension eq "f" &&
					     defined $qualifier && $qualifier !~ /^w/) ||
					    ($extension eq "4" &&
					     defined $qualifier && $qualifier !~ /^cc/)) {
						$bad_specifier = $specifier;
						last;
					}
					if ($extension eq "x" && !defined($stat_real)) {
						if (!defined($stat_real)) {
							$stat_real = get_stat_real($linenr, $lc);
						}
						WARN("VSPRINTF_SPECIFIER_PX",
						     "Using vsprintf specifier '\%px' potentially exposes the kernel memory layout, if you don't really need the address please consider using '\%p'.\n" . "$here\n$stat_real\n");
					}
				}
				if ($bad_specifier ne "") {
					my $stat_real = get_stat_real($linenr, $lc);
					my $ext_type = "Invalid";
					my $use = "";
					if ($bad_specifier =~ /p[Ff]/) {
						$use = " - use %pS instead";
						$use =~ s/pS/ps/ if ($bad_specifier =~ /pf/);
					}

					WARN("VSPRINTF_POINTER_EXTENSION",
					     "$ext_type vsprintf pointer extension '$bad_specifier'$use\n" . "$here\n$stat_real\n");
				}
			}
		}

		if ($perl_version_ok &&
		    $stat =~ /^\+(?:.*?)\bmemset\s*\(\s*$FuncArg\s*,\s*$FuncArg\s*\,\s*$FuncArg\s*\)/) {
#		if ($perl_version_ok &&
#		    defined $stat &&
#		    $stat =~ /^\+(?:.*?)\bmemcpy\s*\(\s*$FuncArg\s*,\s*$FuncArg\s*\,\s*ETH_ALEN\s*\)/) {
#			if (WARN("PREFER_ETHER_ADDR_COPY",
#				 "Prefer ether_addr_copy() over memcpy() if the Ethernet addresses are __aligned(2)\n" . "$here\n$stat\n") &&
#			    $fix) {
#				$fixed[$fixlinenr] =~ s/\bmemcpy\s*\(\s*$FuncArg\s*,\s*$FuncArg\s*\,\s*ETH_ALEN\s*\)/ether_addr_copy($2, $7)/;
#			}
#		}

# Check for memcmp(foo, bar, ETH_ALEN) that could be ether_addr_equal*(foo, bar)
#		if ($perl_version_ok &&
#		    defined $stat &&
#		    $stat =~ /^\+(?:.*?)\bmemcmp\s*\(\s*$FuncArg\s*,\s*$FuncArg\s*\,\s*ETH_ALEN\s*\)/) {
#			WARN("PREFER_ETHER_ADDR_EQUAL",
#			     "Prefer ether_addr_equal() or ether_addr_equal_unaligned() over memcmp()\n" . "$here\n$stat\n")
#		}

# check for memset(foo, 0x0, ETH_ALEN) that could be eth_zero_addr
# check for memset(foo, 0xFF, ETH_ALEN) that could be eth_broadcast_addr
#		if ($perl_version_ok &&
#		    defined $stat &&
#		    $stat =~ /^\+(?:.*?)\bmemset\s*\(\s*$FuncArg\s*,\s*$FuncArg\s*\,\s*ETH_ALEN\s*\)/) {
#
#			my $ms_val = $7;
#
#			if ($ms_val =~ /^(?:0x|)0+$/i) {
#				if (WARN("PREFER_ETH_ZERO_ADDR",
#					 "Prefer eth_zero_addr over memset()\n" . "$here\n$stat\n") &&
#				    $fix) {
#					$fixed[$fixlinenr] =~ s/\bmemset\s*\(\s*$FuncArg\s*,\s*$FuncArg\s*,\s*ETH_ALEN\s*\)/eth_zero_addr($2)/;
#				}
#			} elsif ($ms_val =~ /^(?:0xff|255)$/i) {
#				if (WARN("PREFER_ETH_BROADCAST_ADDR",
#					 "Prefer eth_broadcast_addr() over memset()\n" . "$here\n$stat\n") &&
#				    $fix) {
#					$fixed[$fixlinenr] =~ s/\bmemset\s*\(\s*$FuncArg\s*,\s*$FuncArg\s*,\s*ETH_ALEN\s*\)/eth_broadcast_addr($2)/;
#				}
#			}
#		}

# strlcpy uses that should likely be strscpy
		if ($line =~ /\bstrlcpy\s*\(/) {
			WARN("STRLCPY",
			     "Prefer strscpy over strlcpy - see: https://lore.kernel.org/r/CAHk-=wgfRnXz0W3D37d01q3JFkr_i_uTL=V6A6G1oUZcprmknw\@mail.gmail.com/\n" . $herecurr);
		if ($perl_version_ok &&
		if ($perl_version_ok &&
				     "usleep_range should not use min == max args; see Documentation/timers/timers-howto.rst\n" . "$here\n$stat\n");
				     "usleep_range args reversed, use min then max; see Documentation/timers/timers-howto.rst\n" . "$here\n$stat\n");
		if ($perl_version_ok &&
			my $stat_real = get_stat_real($linenr, $lc);
		if ($perl_version_ok &&
			my $stat_real = get_stat_real($linenr, $lc);
			if ($s =~ /^\s*;/)
# check for function declarations that have arguments without identifier names
		if (defined $stat &&
		    $stat =~ /^.\s*(?:extern\s+)?$Type\s*(?:$Ident|\(\s*\*\s*$Ident\s*\))\s*\(\s*([^{]+)\s*\)\s*;/s &&
		    $1 ne "void") {
			my $args = trim($1);
			while ($args =~ m/\s*($Type\s*(?:$Ident|\(\s*\*\s*$Ident?\s*\)\s*$balanced_parens)?)/g) {
				my $arg = trim($1);
				if ($arg =~ /^$Type$/ && $arg !~ /enum\s+$Ident$/) {
					WARN("FUNCTION_ARGUMENTS",
					     "function definition argument '$arg' should also have an identifier name\n" . $herecurr);
				}
			}
		}

# check for function definitions
		if ($perl_version_ok &&
		    defined $stat &&
		    $stat =~ /^.\s*(?:$Storage\s+)?$Type\s*($Ident)\s*$balanced_parens\s*{/s) {
			$context_function = $1;

# check for multiline function definition with misplaced open brace
			my $ok = 0;
			my $cnt = statement_rawlines($stat);
			my $herectx = $here . "\n";
			for (my $n = 0; $n < $cnt; $n++) {
				my $rl = raw_line($linenr, $n);
				$herectx .=  $rl . "\n";
				$ok = 1 if ($rl =~ /^[ \+]\{/);
				$ok = 1 if ($rl =~ /\{/ && $n == 0);
				last if $rl =~ /^[ \+].*\{/;
			}
			if (!$ok) {
				ERROR("OPEN_BRACE",
				      "open brace '{' following function definitions go on the next line\n" . $herectx);
			}
		}

				    "__setup appears un-documented -- check Documentation/admin-guide/kernel-parameters.txt\n" . $herecurr);
# check for pointless casting of alloc functions
		if ($line =~ /\*\s*\)\s*$allocFunctions\b/) {
		if ($perl_version_ok &&
		    $line =~ /\b($Lval)\s*\=\s*(?:$balanced_parens)?\s*((?:kv|k|v)[mz]alloc(?:_node)?)\s*\(\s*(sizeof\s*\(\s*struct\s+$Lval\s*\))/) {
# check for (kv|k)[mz]alloc with multiplies that could be kmalloc_array/kvmalloc_array/kvcalloc/kcalloc
		if ($perl_version_ok &&
		    defined $stat &&
		    $stat =~ /^\+\s*($Lval)\s*\=\s*(?:$balanced_parens)?\s*((?:kv|k)[mz]alloc)\s*\(\s*($FuncArg)\s*\*\s*($FuncArg)\s*,/) {
			$newfunc = "kvmalloc_array" if ($oldfunc eq "kvmalloc");
			$newfunc = "kvcalloc" if ($oldfunc eq "kvzalloc");
				my $cnt = statement_rawlines($stat);
				my $herectx = get_stat_here($linenr, $cnt, $here);

					 "Prefer $newfunc over $oldfunc with multiply\n" . $herectx) &&
				    $cnt == 1 &&
					$fixed[$fixlinenr] =~ s/\b($Lval)\s*\=\s*(?:$balanced_parens)?\s*((?:kv|k)[mz]alloc)\s*\(\s*($FuncArg)\s*\*\s*($FuncArg)/$1 . ' = ' . "$newfunc(" . trim($r1) . ', ' . trim($r2)/e;
		if ($perl_version_ok &&
		    $line =~ /\b($Lval)\s*\=\s*(?:$balanced_parens)?\s*krealloc\s*\(\s*($Lval)\s*,/ &&
		    $1 eq $3) {
		if ($line =~ /\b((?:devm_)?(?:kcalloc|kmalloc_array))\s*\(\s*sizeof\b/) {
# check for #defines like: 1 << <digit> that could be BIT(digit), it is not exported to uapi
		if ($realfile !~ m@^include/uapi/@ &&
		    $line =~ /#\s*define\s+\w+\s+\(?\s*1\s*([ulUL]*)\s*\<\<\s*(?:\d+|$Ident)\s*\)?/) {
			my $ull = "";
			$ull = "_ULL" if (defined($1) && $1 =~ /ll/i);
			if (CHK("BIT_MACRO",
				"Prefer using the BIT$ull macro\n" . $herecurr) &&
			    $fix) {
				$fixed[$fixlinenr] =~ s/\(?\s*1\s*[ulUL]*\s*<<\s*(\d+|$Ident)\s*\)?/BIT${ull}($1)/;
		}

# check for IS_ENABLED() without CONFIG_<FOO> ($rawline for comments too)
		if ($rawline =~ /\bIS_ENABLED\s*\(\s*(\w+)\s*\)/ && $1 !~ /^${CONFIG_}/) {
			WARN("IS_ENABLED_CONFIG",
			     "IS_ENABLED($1) is normally used as IS_ENABLED(${CONFIG_}$1)\n" . $herecurr);
		}

# check for #if defined CONFIG_<FOO> || defined CONFIG_<FOO>_MODULE
		if ($line =~ /^\+\s*#\s*if\s+defined(?:\s*\(?\s*|\s+)(${CONFIG_}[A-Z_]+)\s*\)?\s*\|\|\s*defined(?:\s*\(?\s*|\s+)\1_MODULE\s*\)?\s*$/) {
			my $config = $1;
			if (WARN("PREFER_IS_ENABLED",
				 "Prefer IS_ENABLED(<FOO>) to ${CONFIG_}<FOO> || ${CONFIG_}<FOO>_MODULE\n" . $herecurr) &&
			    $fix) {
				$fixed[$fixlinenr] = "\+#if IS_ENABLED($config)";
			}
		}

# check for /* fallthrough */ like comment, prefer fallthrough;
		my @fallthroughs = (
			'fallthrough',
			'@fallthrough@',
			'lint -fallthrough[ \t]*',
			'intentional(?:ly)?[ \t]*fall(?:(?:s | |-)[Tt]|t)hr(?:ough|u|ew)',
			'(?:else,?\s*)?FALL(?:S | |-)?THR(?:OUGH|U|EW)[ \t.!]*(?:-[^\n\r]*)?',
			'Fall(?:(?:s | |-)[Tt]|t)hr(?:ough|u|ew)[ \t.!]*(?:-[^\n\r]*)?',
			'fall(?:s | |-)?thr(?:ough|u|ew)[ \t.!]*(?:-[^\n\r]*)?',
		    );
		if ($raw_comment ne '') {
			foreach my $ft (@fallthroughs) {
				if ($raw_comment =~ /$ft/) {
					my $msg_level = \&WARN;
					$msg_level = \&CHK if ($file);
					&{$msg_level}("PREFER_FALLTHROUGH",
						      "Prefer 'fallthrough;' over fallthrough comment\n" . $herecurr);
					last;
				}
		if ($perl_version_ok &&
			my $herectx = get_stat_here($linenr, $cnt, $here);

# check for uses of __DATE__, __TIME__, __TIMESTAMP__
		while ($line =~ /\b(__(?:DATE|TIME|TIMESTAMP)__)\b/g) {
			ERROR("DATE_TIME",
			      "Use of the '$1' macro makes the build non-deterministic\n" . $herecurr);
		}

# check for spin_is_locked(), suggest lockdep instead
		if ($line =~ /\bspin_is_locked\(/) {
			WARN("USE_LOCKDEP",
			     "Where possible, use lockdep_assert_held instead of assertions based on spin_is_locked\n" . $herecurr);
		}

# check for deprecated apis
		if ($line =~ /\b($deprecated_apis_search)\b\s*\(/) {
			my $deprecated_api = $1;
			my $new_api = $deprecated_apis{$deprecated_api};
			WARN("DEPRECATED_API",
			     "Deprecated use of '$deprecated_api', prefer '$new_api' instead\n" . $herecurr);
		}

# check for various structs that are normally const (ops, kgdb, device_tree)
# and avoid what seem like struct definitions 'struct foo {'
		if (defined($const_structs) &&
		    $line !~ /\bconst\b/ &&
		    $line =~ /\bstruct\s+($const_structs)\b(?!\s*\{)/) {
			     "struct $1 should normally be const\n" . $herecurr);
# ignore designated initializers using NR_CPUS
		    $line !~ /\[[^\]]*NR_CPUS[^\]]*\.\.\.[^\]]*\]/ &&
		    $line !~ /^.\s*\.\w+\s*=\s*.*\bNR_CPUS\b/)
# likely/unlikely comparisons similar to "(likely(foo) > 0)"
		if ($perl_version_ok &&
		    $line =~ /\b((?:un)?likely)\s*\(\s*$FuncArg\s*\)\s*$Compare/) {
			WARN("LIKELY_MISUSE",
			     "Using $1 should generally have parentheses around the comparison\n" . $herecurr);
		}

# return sysfs_emit(foo, fmt, ...) fmt without newline
		if ($line =~ /\breturn\s+sysfs_emit\s*\(\s*$FuncArg\s*,\s*($String)/ &&
		    substr($rawline, $-[6], $+[6] - $-[6]) !~ /\\n"$/) {
			my $offset = $+[6] - 1;
			if (WARN("SYSFS_EMIT",
				 "return sysfs_emit(...) formats should include a terminating newline\n" . $herecurr) &&
			    $fix) {
				substr($fixed[$fixlinenr], $offset, 0) = '\\n';
# nested likely/unlikely calls
		if ($line =~ /\b(?:(?:un)?likely)\s*\(\s*!?\s*(IS_ERR(?:_OR_NULL|_VALUE)?|WARN)/) {
			WARN("LIKELY_MISUSE",
			     "nested (un)?likely() calls, $1 already uses unlikely() internally\n" . $herecurr);
		}

		if ($line =~ /debugfs_create_\w+.*\b$mode_perms_world_writable\b/ ||
		    $line =~ /DEVICE_ATTR.*\b$mode_perms_world_writable\b/) {
# check for DEVICE_ATTR uses that could be DEVICE_ATTR_<FOO>
# and whether or not function naming is typical and if
# DEVICE_ATTR permissions uses are unusual too
		if ($perl_version_ok &&
		    defined $stat &&
		    $stat =~ /\bDEVICE_ATTR\s*\(\s*(\w+)\s*,\s*\(?\s*(\s*(?:${multi_mode_perms_string_search}|0[0-7]{3,3})\s*)\s*\)?\s*,\s*(\w+)\s*,\s*(\w+)\s*\)/) {
			my $var = $1;
			my $perms = $2;
			my $show = $3;
			my $store = $4;
			my $octal_perms = perms_to_octal($perms);
			if ($show =~ /^${var}_show$/ &&
			    $store =~ /^${var}_store$/ &&
			    $octal_perms eq "0644") {
				if (WARN("DEVICE_ATTR_RW",
					 "Use DEVICE_ATTR_RW\n" . $herecurr) &&
				    $fix) {
					$fixed[$fixlinenr] =~ s/\bDEVICE_ATTR\s*\(\s*$var\s*,\s*\Q$perms\E\s*,\s*$show\s*,\s*$store\s*\)/DEVICE_ATTR_RW(${var})/;
				}
			} elsif ($show =~ /^${var}_show$/ &&
				 $store =~ /^NULL$/ &&
				 $octal_perms eq "0444") {
				if (WARN("DEVICE_ATTR_RO",
					 "Use DEVICE_ATTR_RO\n" . $herecurr) &&
				    $fix) {
					$fixed[$fixlinenr] =~ s/\bDEVICE_ATTR\s*\(\s*$var\s*,\s*\Q$perms\E\s*,\s*$show\s*,\s*NULL\s*\)/DEVICE_ATTR_RO(${var})/;
				}
			} elsif ($show =~ /^NULL$/ &&
				 $store =~ /^${var}_store$/ &&
				 $octal_perms eq "0200") {
				if (WARN("DEVICE_ATTR_WO",
					 "Use DEVICE_ATTR_WO\n" . $herecurr) &&
				    $fix) {
					$fixed[$fixlinenr] =~ s/\bDEVICE_ATTR\s*\(\s*$var\s*,\s*\Q$perms\E\s*,\s*NULL\s*,\s*$store\s*\)/DEVICE_ATTR_WO(${var})/;
				}
			} elsif ($octal_perms eq "0644" ||
				 $octal_perms eq "0444" ||
				 $octal_perms eq "0200") {
				my $newshow = "$show";
				$newshow = "${var}_show" if ($show ne "NULL" && $show ne "${var}_show");
				my $newstore = $store;
				$newstore = "${var}_store" if ($store ne "NULL" && $store ne "${var}_store");
				my $rename = "";
				if ($show ne $newshow) {
					$rename .= " '$show' to '$newshow'";
				}
				if ($store ne $newstore) {
					$rename .= " '$store' to '$newstore'";
				}
				WARN("DEVICE_ATTR_FUNCTIONS",
				     "Consider renaming function(s)$rename\n" . $herecurr);
			} else {
				WARN("DEVICE_ATTR_PERMS",
				     "DEVICE_ATTR unusual permissions '$perms' used\n" . $herecurr);
			}
		}

# o Ignore module_param*(...) uses with a decimal 0 permission as that has a
#   specific definition of not visible in sysfs.
# o Ignore proc_create*(...) uses with a decimal 0 permission as that means
#   use the default permissions
		if ($perl_version_ok &&
		    defined $stat &&
				my $lc = $stat =~ tr@\n@@;
				$lc = $lc + $linenr;
				my $stat_real = get_stat_real($linenr, $lc);

				my $test = "\\b$func\\s*\\(${skip_args}($FuncArg(?:\\|\\s*$FuncArg)*)\\s*[,\\)]";
				if ($stat =~ /$test/) {
					if (!($func =~ /^(?:module_param|proc_create)/ && $val eq "0") &&
					     ($val =~ /^$Octal$/ && length($val) ne 4))) {
						      "Use 4 digit octal (0777) not decimal permissions\n" . "$here\n" . $stat_real);
					}
					if ($val =~ /^$Octal$/ && (oct($val) & 02)) {
						ERROR("EXPORTED_WORLD_WRITABLE",
						      "Exporting writable files is usually an error. Consider more restrictive permissions.\n" . "$here\n" . $stat_real);

# check for uses of S_<PERMS> that could be octal for readability
		while ($line =~ m{\b($multi_mode_perms_string_search)\b}g) {
			my $oval = $1;
			my $octal = perms_to_octal($oval);
			if (WARN("SYMBOLIC_PERMS",
				 "Symbolic permissions '$oval' are not preferred. Consider using octal permissions '$octal'.\n" . $herecurr) &&
			    $fix) {
				$fixed[$fixlinenr] =~ s/\Q$oval\E/$octal/;
			}
		}

# validate content of MODULE_LICENSE against list from include/linux/module.h
		if ($line =~ /\bMODULE_LICENSE\s*\(\s*($String)\s*\)/) {
			my $extracted_string = get_quoted_string($line, $rawline);
			my $valid_licenses = qr{
						GPL|
						GPL\ v2|
						GPL\ and\ additional\ rights|
						Dual\ BSD/GPL|
						Dual\ MIT/GPL|
						Dual\ MPL/GPL|
						Proprietary
					}x;
			if ($extracted_string !~ /^"(?:$valid_licenses)"$/x) {
				WARN("MODULE_LICENSE",
				     "unknown module license " . $extracted_string . "\n" . $herecurr);
			}
			if (!$file && $extracted_string eq '"GPL v2"') {
				if (WARN("MODULE_LICENSE",
				     "Prefer \"GPL\" over \"GPL v2\" - see commit bf7fbeeae6db (\"module: Cure the MODULE_LICENSE \"GPL\" vs. \"GPL v2\" bogosity\")\n" . $herecurr) &&
				    $fix) {
					$fixed[$fixlinenr] =~ s/\bMODULE_LICENSE\s*\(\s*"GPL v2"\s*\)/MODULE_LICENSE("GPL")/;
				}
			}
		}

# check for sysctl duplicate constants
		if ($line =~ /\.extra[12]\s*=\s*&(zero|one|int_max)\b/) {
			WARN("DUPLICATED_SYSCTL_CONST",
				"duplicated sysctl range checking value '$1', consider using the shared one in include/linux/sysctl.h\n" . $herecurr);
		}
	# This is not a patch, and we are in 'no-patch' mode so
	if (!$is_patch && $filename !~ /cover-letter\.patch$/) {
	if ($is_patch && $has_commit_log && $chk_signoff) {
		if ($signoff == 0) {
			ERROR("MISSING_SIGN_OFF",
			      "Missing Signed-off-by: line(s)\n");
		} elsif ($authorsignoff != 1) {
			# authorsignoff values:
			# 0 -> missing sign off
			# 1 -> sign off identical
			# 2 -> names and addresses match, comments mismatch
			# 3 -> addresses match, names different
			# 4 -> names match, addresses different
			# 5 -> names match, addresses excluding subaddress details (refer RFC 5233) match

			my $sob_msg = "'From: $author' != 'Signed-off-by: $author_sob'";

			if ($authorsignoff == 0) {
				ERROR("NO_AUTHOR_SIGN_OFF",
				      "Missing Signed-off-by: line by nominal patch author '$author'\n");
			} elsif ($authorsignoff == 2) {
				CHK("FROM_SIGN_OFF_MISMATCH",
				    "From:/Signed-off-by: email comments mismatch: $sob_msg\n");
			} elsif ($authorsignoff == 3) {
				WARN("FROM_SIGN_OFF_MISMATCH",
				     "From:/Signed-off-by: email name mismatch: $sob_msg\n");
			} elsif ($authorsignoff == 4) {
				WARN("FROM_SIGN_OFF_MISMATCH",
				     "From:/Signed-off-by: email address mismatch: $sob_msg\n");
			} elsif ($authorsignoff == 5) {
				WARN("FROM_SIGN_OFF_MISMATCH",
				     "From:/Signed-off-by: email subaddress mismatch: $sob_msg\n");
			}
		}
		# If there were any defects found and not already fixing them
		if (!$clean and !$fix) {
			print << "EOM"
NOTE: For some of the reported defects, checkpatch may be able to
      mechanically convert to the typical style using --fix or --fix-inplace.
EOM
			print << "EOM"

NOTE: Whitespace errors detected.
      You may wish to use scripts/cleanpatch or scripts/cleanfile
EOM

	if ($quiet == 0) {
		print "\n";
		if ($clean == 1) {
			print "$vname has no obvious style problems and is ready for submission.\n";
		} else {
			print "$vname has style problems, please review.\n";
		}