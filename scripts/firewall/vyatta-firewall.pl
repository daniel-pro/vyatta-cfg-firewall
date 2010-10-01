#!/usr/bin/perl

use lib "/opt/vyatta/share/perl5";
use warnings;
use strict;

use Vyatta::Config;
use Vyatta::IpTables::Rule;
use Vyatta::IpTables::AddressFilter;
use Vyatta::IpTables::Mgr;
use Getopt::Long;
use Vyatta::Zone;


# Send output of shell commands to syslog for debugging and so that
# the user is not confused by it.  Log at debug level, which is supressed
# by default, so that we don't unnecessarily fill up the syslog file.
my $logger = 'logger -t firewall-cfg -p local0.debug --';

# Enable printing debug output to stdout.
my $debug_flag = 0;

# Enable sending debug output to syslog.
my $syslog_flag = 0;

my $fw_stateful_file = '/var/run/vyatta_fw_stateful';
my $fw_tree_file     = '/var/run/vyatta_fw_trees';

my $max_rule = 10000;

my (@setup, @updateints, @updaterules);
my ($teardown, $teardown_ok);

GetOptions("setup=s{2}"        => \@setup, 
           "teardown=s"        => \$teardown,
           "teardown-ok=s"     => \$teardown_ok,
 	   "update-rules=s{2}" => \@updaterules,
	   "update-interfaces=s{5}" => \@updateints,
           "debug"             => \$debug_flag,
           "syslog"            => \$syslog_flag
);

# mapping from config node to iptables/ip6tables table
my %table_hash = ( 'name'        => 'filter',
		   'ipv6-name'   => 'filter',
                   'modify'      => 'mangle',
                   'ipv6-modify' => 'mangle' );

# mapping from config node to iptables command.  Note that this table
# has the same keys as %table hash, so a loop iterating through the 
# keys of %table_hash can use the same keys to find the value associated
# with the key in this table.
my %cmd_hash = ( 'name'        => 'iptables',
		 'ipv6-name'   => 'ip6tables',
		 'modify'      => 'iptables',
                 'ipv6-modify' => 'ip6tables');

# mapping from config node to IP version string.
my %ip_version_hash = ( 'name'        => 'ipv4',
                        'ipv6-name'   => 'ipv6',
                        'modify'      => 'ipv4',
                        'ipv6-modify' => 'ipv6');

# mapping from firewall tree to builtin chain for input
my %inhook_hash =  ( 'filter' => 'FORWARD',
	   	     'mangle' => 'PREROUTING' );

# mapping from firewall tree to builtin chain for output
my %outhook_hash = ( 'filter' => 'FORWARD',
	   	     'mangle' => 'POSTROUTING' );

# mapping from vyatta 'default-policy' to iptables jump target
my %policy_hash = ( 'drop'    => 'DROP',
                    'reject'  => 'REJECT',
                    'accept'  => 'RETURN' );

my %other_tree = (  'name'        => 'modify',
                    'modify'      => 'name',
                    'ipv6-name'   => 'ipv6-modify',
                    'ipv6-modify' => 'ipv6-name');

sub log_msg {
  my $message = shift;

  print "DEBUG: $message" if $debug_flag;
  system("$logger DEBUG: \"$message\"") if $syslog_flag;
}

sub other_table {
  my $this = shift;
  return (($this eq 'filter') ? 'mangle' : 'filter');
}

if (scalar(@setup) == 2) {
  setup_iptables(@setup);
  exit 0;
}

if (scalar(@updaterules) == 2) {
  update_rules(@updaterules);
  exit 0;
}

if ($#updateints == 4) {
  my ($action, $int_name, $direction, $chain, $tree) = @updateints;
  
  log_msg "updateints [$action][$int_name][$direction][$chain][$tree]\n";
  my ($table, $iptables_cmd) = (undef, undef);

  my $tree2     = chain_configured(1, $chain, $tree);
  $table        = $table_hash{$tree};
  $iptables_cmd = $cmd_hash{$tree};

  if ($action eq "update") {
    # make sure interface is not being used in a zone
    my @all_zones = Vyatta::Zone::get_all_zones("listNodes");
    foreach my $zone (@all_zones) {
      my @zone_interfaces =
         Vyatta::Zone::get_zone_interfaces("returnValues", $zone);
      if (scalar(grep(/^$int_name$/, @zone_interfaces)) > 0) {
        print STDERR 'Firewall config error: ' .
                   "interface $int_name is defined under zone $zone\n" .
        "Cannot use per interface firewall for a zone interface\n";
        exit 1;
      }
    }

    # make sure chain exists
    if (!defined($tree2)) {
      # require chain to be configured in "firewall" first
      print STDERR 'Firewall config error: ' .
                   "Rule set \"$chain\" is not configured\n";
      exit 1;
    }

    # do update action.
    update_ints(@updateints, $table, $iptables_cmd);
  } else {
    # delete
    update_ints(@updateints, $table, $iptables_cmd);
  }
  exit 0;
}

sub find_chain_rule {
  my ($iptables_cmd, $table, $chain, $search) = @_;
  
  my ($num, $chain2) = (undef, undef);
  my $cmd = "$iptables_cmd -t $table -L $chain -vn --line";
  my @lines = `$cmd 2> /dev/null | egrep ^[0-9]`;
  if (scalar(@lines) < 1) {
    system("$logger DEBUG: find_chain_rule: @_ = none \n") if $syslog_flag;
    return;
  }
  foreach my $line (@lines) {
    ($num, undef, undef, $chain2) = split /\s+/, $line;
    last if $chain2 eq $search;
    ($num, $chain2) = (undef, undef);
  }

  if ($syslog_flag) {
    my $tmp_num = $num ? $num : -1;
    system("$logger DEBUG: find_chain_rule: @_ = $tmp_num");
  }

  return $num if defined $num;
  return;
}

if (defined $teardown_ok) {
  my $rc = is_tree_in_use($teardown_ok);
  log_msg "teardown_ok($teardown_ok) = [$rc]\n";
  exit $rc;
}

if (defined $teardown) {
  my $table        = $table_hash{$teardown};
  my $iptables_cmd = $cmd_hash{$teardown};
  log_msg "teardown [$table][$iptables_cmd]\n";
  teardown_iptables($table, $iptables_cmd);

  # remove the conntrack setup.
  if (! is_tree_in_use($other_tree{$teardown})) {
    ipt_disable_conntrack($iptables_cmd, 'FW_CONNTRACK');
  }

  exit 0;
}

help();
exit 1;

sub help {
  print "usage: vyatta-firewall.pl\n";
  print "\t--setup              setup Vyatta specific iptables settings\n";
  print "\t--update-rules       update iptables with the current firewall rules\n";
  print "\t--update-interfaces  update the rules applpied to interfaces\n";
  print "\t                     (<action> <interface> <direction> <chain name>)\n";
  print "\t--teardown           teardown all user rules and iptables settings\n";
  print "\n";
}

sub run_cmd {
  my ($cmd_to_run, $redirect_flag, $logger_flag) = @_;

  my $cmd_extras = '';
  
  print "DEBUG: Running: $cmd_to_run \n" if $debug_flag;
  
  system("$logger DEBUG: Running: $cmd_to_run") if $syslog_flag;
  
  $cmd_extras  = ' 2>&1' if $redirect_flag;
  $cmd_extras .= " | $logger" if $logger_flag;
  
  system("$cmd_to_run $cmd_extras");
}

sub read_refcnt_file {
    my ($refcnt_file) = @_;

    my @lines = ();
    if ( -e $refcnt_file) {
      open(my $FILE, '<', $refcnt_file) or die "Error: read $!";
      @lines = <$FILE>;
      close($FILE);
      chomp @lines;
    }
    return @lines;
}

sub write_refcnt_file {
    my ($refcnt_file, @lines) = @_;	    

    if (scalar(@lines) > 0) {
      open(my $FILE, '>', $refcnt_file) or die "Error: write $!";
      print $FILE join("\n", @lines), "\n";
      close($FILE);
    } else {
      system("rm $refcnt_file");
    }
}

sub add_refcnt {
  my ($file, $value) = @_;
    
  log_msg "add_refcnt($file, $value)\n";
  my @lines = read_refcnt_file($file);
  foreach my $line (@lines) {
    return if $line eq $value;
  }
  push @lines, $value;
  write_refcnt_file($file, @lines);
  return @lines; 
}

sub remove_refcnt {
  my ($file, $value) = @_;

  log_msg "remove_refcnt($file, $value)\n";
  my @lines = read_refcnt_file($file);
  my @new_lines = ();
  foreach my $line (@lines) {
    push @new_lines, $line if $line ne $value;
  }
  write_refcnt_file($file, @new_lines) if scalar(@lines) ne scalar(@new_lines);
  return @new_lines;
}

sub is_conntrack_enabled {
  my ($iptables_cmd) = @_;
  
  my @lines = read_refcnt_file($fw_stateful_file);
  return 0 if scalar(@lines) < 1;

  foreach my $line (@lines) {
    if ($line =~ /^([^\s]+)\s([^\s]+)$/) {
      my ($tree, $chain) = ($1, $2);
      return 1 if $cmd_hash{$tree} eq $iptables_cmd;
    } else {
      die "Error: unexpected format [$line]\n";
    }
  }

  return 0;
}

sub is_tree_in_use {
  my ($tree) = @_;

  my @lines = read_refcnt_file($fw_tree_file);
  my %tree_hash;
  foreach my $line (@lines) {
    if ($line =~ /^([^\s]+)\s([^\s]+)$/) {
      my ($tmp_tree, $tmp_chain) = ($1, $2);
      $tree_hash{$tmp_tree}++;
    } else {
      die "Error: unexpected format [$line]\n";
    }
  }
  my $rc;
  $rc = $tree_hash{$tree} ? 1 : 0;
  log_msg "is_tree_in_use($tree) = $rc\n";
  return $rc;
}


sub update_rules {
  my ($tree, $name) = @_;	        # name, modify, ipv6-name or ipv6-modify
  my $table = $table_hash{$tree};	# "filter" or "mangle"
  my $iptables_cmd = $cmd_hash{$tree};  # "iptables" or "ip6tables"
  my $config = new Vyatta::Config;
  my %nodes = ();

  log_msg "update_rules: $tree $name $table $iptables_cmd\n";

  $config->setLevel("firewall $tree");

  %nodes = $config->listNodeStatus();

  # by default, nothing needs to be tracked.
  my $chain_stateful = 0;

  $config->setLevel("firewall $tree $name");
  my $policy = $config->returnValue('default-action');
  $policy = 'drop' if ! defined $policy;
  my $old_policy = $config->returnOrigValue('default-action');
  my $policy_log = $config->exists('enable-default-log');
  $policy_log = 0 if ! defined $policy_log;
  my $old_policy_log = $config->existsOrig('enable-default-log');
  $old_policy_log = 0 if ! defined $old_policy_log;
  my $policy_set = 0;
  log_msg "update_rules: [$name] = [$nodes{$name}], policy [$policy] log [$policy_log]\n";

  if ($nodes{$name} eq 'static') {
    # not changed. check if stateful.
    log_msg "$tree $name = static\n";
    $config->setLevel("firewall $tree $name rule");
    my @rules = $config->listOrigNodes();
    foreach (sort numerically @rules) {
      my $node = new Vyatta::IpTables::Rule;
      $node->setupOrig("firewall $tree $name rule $_");
      $node->set_ip_version($ip_version_hash{$tree});
      if ($node->is_stateful()) {
        $chain_stateful = 1;
      }
    }
  } elsif ($nodes{$name} eq 'added') {
    log_msg "$tree $name = added\n";
    # create the chain
    my $ctree = chain_configured(2, $name, $tree);
    if (defined($ctree)) {
      # chain name must be unique in both trees
      printf STDERR 'Firewall config error: '
          . "Rule set name \"$name\" already used in \"$ctree\"\n";
      exit 1;
    }
    setup_chain($table, "$name", $iptables_cmd, $policy, $policy_log);
    add_refcnt($fw_tree_file, "$tree $name");
    $policy_set = 1;
    # handle the rules below.
  } elsif ($nodes{$name} eq 'deleted') {

    log_msg "$tree $name = deleted\n";

    # delete the chain
    if (Vyatta::IpTables::Mgr::chain_referenced($table, $name, $iptables_cmd)) {
      # disallow deleting a chain if it's still referenced
      print STDERR 'Firewall config error: '
          . "Cannot delete rule set \"$name\" (still in use)\n";
      exit 1;
    }
    delete_chain($table, "$name", $iptables_cmd);
    remove_refcnt($fw_tree_file, "$tree $name");
    goto end_of_rules;
  } elsif ($nodes{$name} eq 'changed') {
    log_msg "$tree $name = changed\n";
    # handle the rules below.
  }

  # set our config level to rule and get the rule numbers 
  $config->setLevel("firewall $tree $name rule");

  # Let's find the status of the rule nodes
  my %rulehash = ();
  %rulehash = $config->listNodeStatus();
  if ((scalar (keys %rulehash)) == 0) {
    # no rules. flush the user rules.
    # note that this clears the counters on the default DROP rule.
    # we could delete rule one by one if those are important.
    run_cmd("$iptables_cmd -t $table -F $name", 1, 1);
    set_default_policy($table, $name, $iptables_cmd, $policy, $policy_log);
  }
  
  my $iptablesrule = 1;
  foreach my $rule (sort numerically keys %rulehash) {
    if ("$rulehash{$rule}" eq 'static') {
      my $node = new Vyatta::IpTables::Rule;
      $node->setupOrig("firewall $tree $name rule $rule");
      $node->set_ip_version($ip_version_hash{$tree});
      if ($node->is_stateful()) {
        $chain_stateful = 1;
      }
      my $ipt_rules = $node->get_num_ipt_rules();
      $iptablesrule += $ipt_rules;
    } elsif ("$rulehash{$rule}" eq 'added') {
      # create a new iptables object of the current rule
      my $node = new Vyatta::IpTables::Rule;
      $node->setup("firewall $tree $name rule $rule");
      $node->set_ip_version($ip_version_hash{$tree});
      if ($node->is_stateful()) {
        $chain_stateful = 1;
      }
      
      my ($err_str, @rule_strs) = $node->rule();
      if (defined($err_str)) {
        if ($nodes{$name} eq 'added') {
          # undo setup_chain work, remove_refcnt
          delete_chain($table, "$name", $iptables_cmd);
          remove_refcnt($fw_tree_file, "$tree $name");
        }
        print STDERR "Firewall config error: $err_str\n";
        exit 1;
      }
      foreach (@rule_strs) {
        if (!defined) {
          next;
        }
          
        run_cmd("$iptables_cmd -t $table --insert $name $iptablesrule $_", 
                0, 0);
        if ($? >> 8) {
          if ($nodes{$name} eq 'added') {
            # undo setup_chain work, remove_refcnt
            delete_chain($table, "$name", $iptables_cmd);
            remove_refcnt($fw_tree_file, "$tree $name");
          }
          die "$iptables_cmd error: $! - $_";
        }
        $iptablesrule++;
      }
    } elsif ("$rulehash{$rule}" eq 'changed') {
      # create a new iptables object of the current rule
      my $oldnode = new Vyatta::IpTables::Rule;
      $oldnode->setupOrig("firewall $tree $name rule $rule");
      $oldnode->set_ip_version($ip_version_hash{$tree});
      my $node = new Vyatta::IpTables::Rule;
      $node->setup("firewall $tree $name rule $rule");
      $node->set_ip_version($ip_version_hash{$tree});
      if ($node->is_stateful()) {
        $chain_stateful = 1;
      }
      
      my ($err_str, @rule_strs) = $node->rule();
      if (defined($err_str)) {
        print STDERR "Firewall config error: $err_str\n";
        exit 1;
      }
      
      my $ipt_rules = $oldnode->get_num_ipt_rules();
      for (1 .. $ipt_rules) {
        run_cmd("$iptables_cmd -t $table --delete $name $iptablesrule", 0,
                0);
        die "$iptables_cmd error: $! - $rule" if ($? >> 8);
      }
      
      foreach (@rule_strs) {
        if (!defined) {
          next;
        }
        run_cmd("$iptables_cmd -t $table --insert $name $iptablesrule $_", 
                0, 0);
        die "$iptables_cmd error: $! - " , join(' ', @rule_strs) if ($? >> 8);
        $iptablesrule++;
      }
    } elsif ("$rulehash{$rule}" eq 'deleted') {
      my $node = new Vyatta::IpTables::Rule;
      $node->setupOrig("firewall $tree $name rule $rule");
      $node->set_ip_version($ip_version_hash{$tree});
      
      my $ipt_rules = $node->get_num_ipt_rules();
      for (1 .. $ipt_rules) {
        run_cmd("$iptables_cmd -t $table --delete $name $iptablesrule", 
                0, 0);
        die "$iptables_cmd error: $! - $rule" if ($? >> 8);
      }
    }
  } # foreach rule
    
  goto end_of_rules if $policy_set;

  if ((defined $old_policy and $policy ne $old_policy) or 
      ($old_policy_log ne $policy_log)) {
    change_default_policy($table, $name, $iptables_cmd, $policy, 
                          $old_policy_log,$policy_log);
  }

end_of_rules:

  #
  # check if conntrack needs to be enabled/disabled
  #
  my $global_stateful = is_conntrack_enabled($iptables_cmd);
  log_msg "stateful [$tree][$name] = [$global_stateful][$chain_stateful]\n";
  if ($chain_stateful) {
    add_refcnt($fw_stateful_file, "$tree $name");
    enable_fw_conntrack($iptables_cmd) if ! $global_stateful;
  } else {
    remove_refcnt($fw_stateful_file, "$tree $name");
    disable_fw_conntrack($iptables_cmd) if ! is_conntrack_enabled($iptables_cmd);
  }
}

# returns the "tree" in which the chain is configured; undef if not configured.
# mode: 0: check if the chain is configured in any tree.
#       1: check if it is configured in the specified tree.
#       2: check if it is configured in any "other" tree.
sub chain_configured {
  my ($mode, $chain, $tree) = @_;
  
  my $config = new Vyatta::Config;
  my %chains = ();
  log_msg "chain_configured($mode, $chain, $tree)\n";
  foreach (keys %table_hash) {
    next if ($mode == 1 && $_ ne $tree);
    next if ($mode == 2 && $_ eq $tree);
 
    $config->setLevel("firewall $_");
    %chains = $config->listNodeStatus();

    if (grep(/^$chain$/, (keys %chains))) {
      if ($chains{$chain} ne "deleted") {
        log_msg "found $_\n";
        return $_;
      }
    }
  }
  log_msg "not found\n";
  return; # undef
}

sub update_ints {
  my ($action, $int_name, $direction, $chain, $tree, $table, $iptables_cmd) = @_;
  my $interface = undef;
 
  log_msg "update_ints: @_ \n";

  if (! defined $action || ! defined $int_name || ! defined $direction
      || ! defined $chain || ! defined $table || ! defined $iptables_cmd) {
    return -1;
  }

  if ($action ne 'delete' && $table eq 'mangle' && $direction =~ /^local/) {
    print STDERR 'Firewall config error: ' .
                 "\"Modify\" rule set \"$chain\" cannot be used for " .
                 "\"local\"\n";
    exit 1;
  }

  $_ = $direction;
  my $dir_str = $direction;

  CASE: {
    /^in/    && do {
             $direction = 'VYATTA_IN_HOOK';
             $interface = "--in-interface $int_name";
             last CASE;
             };

    /^out/   && do {   
             $direction = 'VYATTA_OUT_HOOK';
             $interface = "--out-interface $int_name";
             last CASE;
             };

    /^local/ && do {
             # mangle disallowed above
             $direction = "INPUT";
             $interface = "--in-interface $int_name";
             last CASE;
             };
    }

  # In the update case, we want to see if the new rule will replace one
  # that is already in the table.  In the delete case, we need to find
  # the rule in the table that we need to delete.  Either way, we
  # start by listing the rules rules already in the table.
  my $grep = "egrep ^[0-9] | grep $int_name";
  my @lines
    = `$iptables_cmd -t $table -L $direction -n -v --line-numbers | $grep`;
  my ($cmd, $num, $oldchain, $in, $out, $ignore)
    = (undef, undef, undef, undef, undef, undef);

  foreach (@lines) {
    # Parse the line representing one rule in the table.  Note that
    # there is a slight difference in output format between the "iptables"
    # and "ip6tables" comands.  The "iptables" command displays "--" in
    # the "opt" column, while the "ip6tables" command leaves that
    # column blank.
    if ($iptables_cmd eq "iptables") {
      ($num, $ignore, $ignore, $oldchain, $ignore, $ignore, $in, $out,
       $ignore, $ignore) = split /\s+/;
    } else {
      ($num, $ignore, $ignore, $oldchain, $ignore,  $in, $out,
       $ignore, $ignore) = split /\s+/;
    }

    # Look for a matching rule...
    if (($dir_str eq 'in' && $in eq $int_name) 
        || ($dir_str eq 'out' && $out eq $int_name)
        || ($dir_str eq 'local' && $in eq $int_name)) {
      # found a matching rule
      if ($action eq 'update') {
        # replace old rule
        $action = 'replace';
        $cmd = "--replace $direction $num $interface --jump $chain";
      } else {
        # delete old rule
        $cmd = "--delete $direction $num";
      }
      last;
    }
  }

  if (!defined($cmd)) {
    # no matching rule
    if ($action eq 'update') {
      # add new rule.
      # there is a post-fw rule at the end. insert at the front.      
      $cmd = "--insert $direction 1 $interface --jump $chain";
    } else {
      # delete non-existent rule!
      # not an error. rule may be in the other table.
    }
  }

  # no match. do nothing.
  return 0 if (!defined($cmd));

  run_cmd("$iptables_cmd -t $table $cmd", 0, 0);
  exit 1 if ($? >> 8);
 
  return 0;
}

sub enable_fw_conntrack {
  # potentially we can add rules in the FW_CONNTRACK chain to provide
  # finer-grained control over which packets are tracked.
  my $iptables_cmd = shift;
  log_msg("enable_fw_conntrack($iptables_cmd)\n");
  run_cmd("$iptables_cmd -t raw -R FW_CONNTRACK 1 -j ACCEPT", 1, 1);
}

sub disable_fw_conntrack {
  my $iptables_cmd = shift;
  log_msg("disable_fw_conntrack\($iptables_cmd\)\n");
  run_cmd("$iptables_cmd -t raw -R FW_CONNTRACK 1 -j RETURN", 1, 1);
}


sub teardown_iptables {
  my ($table, $iptables_cmd) = @_;
  log_msg "teardown_iptables executing: $iptables_cmd -L -n -t $table\n";
  my @chains = `$iptables_cmd -L -n -t $table`;
  my $chain;

  # remove VYATTA_(IN|OUT)_HOOK
  my $ihook = $inhook_hash{$table};
  my $num = find_chain_rule($iptables_cmd, $table, $ihook, 'VYATTA_IN_HOOK');
  if (defined $num) {
    run_cmd("$iptables_cmd -t $table -D $ihook $num", 1, 1);
    run_cmd("$iptables_cmd -t $table -F VYATTA_IN_HOOK", 1, 1);
    run_cmd("$iptables_cmd -t $table -X VYATTA_IN_HOOK", 1, 1);
  }
  my $ohook = $outhook_hash{$table};
  $num = find_chain_rule($iptables_cmd, $table, $ohook, 'VYATTA_OUT_HOOK');
  if (defined $num) {
    run_cmd("$iptables_cmd -t $table -D $ohook $num", 1, 1);
    run_cmd("$iptables_cmd -t $table -F VYATTA_OUT_HOOK", 1, 1);
    run_cmd("$iptables_cmd -t $table -X VYATTA_OUT_HOOK", 1, 1);
  }
}

sub setup_iptables {
  my ($iptables_cmd, $tree) = @_;

  log_msg "setup_iptables [$iptables_cmd] [$table_hash{$tree}]\n";
  my $table = $table_hash{$tree};
  my $ihook = $inhook_hash{$table};
  my $ohook = $outhook_hash{$table};
  # add VYATTA_(IN|OUT)_HOOK
  my $num = find_chain_rule($iptables_cmd, $table, $ohook, 'VYATTA_OUT_HOOK');
  if (! defined $num) {
    run_cmd("$iptables_cmd -t $table -N VYATTA_OUT_HOOK", 1, 1);
    run_cmd("$iptables_cmd -t $table -I $ohook 1 -j VYATTA_OUT_HOOK", 1, 1);
    run_cmd("$iptables_cmd -t $table -N VYATTA_IN_HOOK", 1, 1);
    run_cmd("$iptables_cmd -t $table -I $ihook 1 -j VYATTA_IN_HOOK", 1, 1);
  }

  # by default, nothing is tracked (the last rule in raw/PREROUTING).
  my $cnt = Vyatta::IpTables::Mgr::count_iptables_rules($iptables_cmd, 'raw', 'FW_CONNTRACK');
  if ($cnt == 0) {
    ipt_enable_conntrack($iptables_cmd, 'FW_CONNTRACK');
    disable_fw_conntrack($iptables_cmd);
  } else {
    log_msg "FW_CONNTRACK exists $cnt\n";
  }

  return 0;
}

sub set_default_policy {
  my ($table, $chain, $iptables_cmd, $policy, $log) = @_;

  $policy = 'drop' if ! defined $policy;
  log_msg("set_default_policy($iptables_cmd, $table, $chain, $policy, $log)\n");
  my $target = $policy_hash{$policy};
  my $comment = "-m comment --comment \"$chain-$max_rule default-action $policy\"";
  if ($log) {
    my $action_char = uc(substr($policy, 0, 1));
    my $ltarget = "LOG --log-prefix \"[$chain-default-$action_char]\" ";
    run_cmd("$iptables_cmd -t $table -A $chain $comment -j $ltarget", 1, 1);
  }
  run_cmd("$iptables_cmd -t $table -A $chain $comment -j $target", 1, 1);
}

sub change_default_policy {
  my ($table, $chain, $iptables_cmd, $policy, $old_log, $log) = @_;

  $policy = 'drop' if ! defined $policy;
  log_msg("change_default_policy($iptables_cmd, $table, $chain, $policy)\n");  

  # count the number of rules before adding the new policy
  my $default_rule = Vyatta::IpTables::Mgr::count_iptables_rules($iptables_cmd, $table, $chain);

  # add new policy after existing policy
  set_default_policy($table, $chain, $iptables_cmd, $policy, $log);

  # remove old policy
  if (defined $old_log and $old_log == 1) {
    if ($default_rule < 2) {
      log_msg "unexpected rule number [$default_rule]\n";
    } {
      # we counted all the rules, but need to removed the last
      # two.  decrement the index and delete that index twice.
      $default_rule--;
      run_cmd("$iptables_cmd -t $table -D $chain $default_rule", 1, 1);    
    }
  }
  run_cmd("$iptables_cmd -t $table -D $chain $default_rule", 1, 1);
}

sub setup_chain {
  my ($table, $chain, $iptables_cmd, $policy, $log) = @_;

  my $configured = `$iptables_cmd -t $table -n -L $chain 2>&1 | head -1`;

  $_ = $configured;
  if (!/^Chain $chain/) {
    run_cmd("$iptables_cmd -t $table --new-chain $chain", 0, 0);
    die "iptables error: $table $chain --new-chain: $!" if ($? >> 8);
    set_default_policy($table, $chain, $iptables_cmd, $policy, $log);
  } else {
      printf STDERR 'Firewall config error: '
. "Chain \"$chain\" being used in system. Cannot use it as a ruleset name\n";
      exit 1;
  }
}

sub chain_referenced_count {
  my ($table, $chain, $iptables_cmd) = @_;

  log_msg "chain_referenced_count: $iptables_cmd -t $table -n -L $chain\n";

  my $cmd = "$iptables_cmd -t $table -n -L $chain";
  my $line = `$iptables_cmd -t $table -n -L $chain 2>/dev/null |head -n1`;
  chomp $line;
  if ($line =~ m/^Chain $chain \((\d+) references\)$/) {
    return $1;
  }
  return;
}

sub delete_chain {
  my ($table, $chain, $iptables_cmd) = @_;
  
  log_msg "delete_chain: $iptables_cmd -t $table -n -L $chain\n";

  my $configured = `$iptables_cmd -t $table -n -L $chain 2>&1 | head -1`;

  if ($configured =~ /^Chain $chain/) {
    if (!Vyatta::IpTables::Mgr::chain_referenced($table, $chain, $iptables_cmd)) {
      run_cmd("$iptables_cmd -t $table --flush $chain", 0, 0);
      die "$iptables_cmd error: $table $chain --flush: $!" if ($? >> 8);
      run_cmd("$iptables_cmd -t $table --delete-chain $chain", 0, 0);
      die "$iptables_cmd error: $table $chain --delete-chain: $!" if ($? >> 8);
    } 
  }
}

sub numerically { $a <=> $b; }

# Local Variables:
# mode: perl
# indent-tabs-mode: nil
# perl-indent-level: 2
# End:
