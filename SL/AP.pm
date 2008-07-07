#=====================================================================
# LX-Office ERP
# Copyright (C) 2004
# Based on SQL-Ledger Version 2.1.9
# Web http://www.lx-office.org
#
#=====================================================================
# SQL-Ledger Accounting
# Copyright (C) 2001
#
#  Author: Dieter Simader
#   Email: dsimader@sql-ledger.org
#     Web: http://www.sql-ledger.org
#
#  Contributors:
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.
#======================================================================
#
# Accounts Payables database backend routines
#
#======================================================================

package AP;

use SL::DBUtils;
use SL::MoreCommon;

sub post_transaction {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig, $form, $provided_dbh, $payments_only) = @_;

  # connect to database
  my $dbh = $provided_dbh ? $provided_dbh : $form->dbconnect_noauto($myconfig);

  my ($null, $taxrate, $amount);
  my $exchangerate = 0;

  $form->{defaultcurrency} = $form->get_default_currency($myconfig);

  ($null, $form->{department_id}) = split(/--/, $form->{department});
  $form->{department_id} *= 1;

  if ($form->{currency} eq $form->{defaultcurrency}) {
    $form->{exchangerate} = 1;
  } else {
    $exchangerate         = $form->check_exchangerate($myconfig, $form->{currency}, $form->{transdate}, 'sell');
    $form->{exchangerate} = $exchangerate || $form->parse_amount($myconfig, $form->{exchangerate});
  }

  for $i (1 .. $form->{rowcount}) {
    $form->{AP_amounts}{"amount_$i"} =
      (split(/--/, $form->{"AP_amount_$i"}))[0];
  }
  ($form->{AP_amounts}{payables}) = split(/--/, $form->{APselected});
  ($form->{AP}{payables})         = split(/--/, $form->{APselected});

  # reverse and parse amounts
  for my $i (1 .. $form->{rowcount}) {
    $form->{"amount_$i"} =
      $form->round_amount(
                         $form->parse_amount($myconfig, $form->{"amount_$i"}) *
                           $form->{exchangerate} * -1,
                         2);
    $amount += ($form->{"amount_$i"} * -1);

    # parse tax_$i for later
    $form->{"tax_$i"} = $form->parse_amount($myconfig, $form->{"tax_$i"}) * -1;
  }

  # this is for ap
  $form->{amount} = $amount;

  # taxincluded doesn't make sense if there is no amount
  $form->{taxincluded} = 0 if ($form->{amount} == 0);

  for $i (1 .. $form->{rowcount}) {
    ($form->{"tax_id_$i"}, $NULL) = split /--/, $form->{"taxchart_$i"};

    $query =
      qq|SELECT c.accno, t.taxkey, t.rate | .
      qq|FROM tax t LEFT JOIN chart c on (c.id=t.chart_id) | .
      qq|WHERE t.id = ? | .
      qq|ORDER BY c.accno|;
    $sth = $dbh->prepare($query);
    $sth->execute($form->{"tax_id_$i"}) || $form->dberror($query . " (" . $form->{"tax_id_$i"} . ")");
    ($form->{AP_amounts}{"tax_$i"}, $form->{"taxkey_$i"}, $form->{"taxrate_$i"}) =
      $sth->fetchrow_array;
    $form->{AP_amounts}{"tax_$i"}{taxkey}    = $form->{"taxkey_$i"};
    $form->{AP_amounts}{"amount_$i"}{taxkey} = $form->{"taxkey_$i"};

    $sth->finish;
    if ($form->{taxincluded} *= 1) {
      if (!$form->{"korrektur_$i"}) {
        $tax =
          $form->{"amount_$i"} -
          ($form->{"amount_$i"} / ($form->{"taxrate_$i"} + 1));
      } else {
        $tax = $form->{"tax_$i"};
      }
      $amount = $form->{"amount_$i"} - $tax;
      $form->{"amount_$i"} = $form->round_amount($amount, 2);
      $diff += $amount - $form->{"amount_$i"};
      $form->{"tax_$i"} = $form->round_amount($tax, 2);
      $form->{netamount} += $form->{"amount_$i"};
    } else {
      if (!$form->{"korrektur_$i"}) {
        $form->{"tax_$i"} = $form->{"amount_$i"} * $form->{"taxrate_$i"};
      } else {
        $tax = $form->{"tax_$i"};
      }
      $form->{"tax_$i"} =
        $form->round_amount($form->{"tax_$i"} * $form->{exchangerate}, 2);
      $form->{netamount} += $form->{"amount_$i"};
    }
    $form->{total_tax} += $form->{"tax_$i"} * -1;
  }

  # adjust paidaccounts if there is no date in the last row
  $form->{paidaccounts}-- unless ($form->{"datepaid_$form->{paidaccounts}"});

  $form->{invpaid} = 0;
  $form->{netamount} *= -1;

  # add payments
  for my $i (1 .. $form->{paidaccounts}) {
    $form->{"paid_$i"} =
      $form->round_amount($form->parse_amount($myconfig, $form->{"paid_$i"}),
                          2);

    $form->{invpaid} += $form->{"paid_$i"};
    $form->{datepaid} = $form->{"datepaid_$i"};

  }

  $form->{invpaid} =
    $form->round_amount($form->{invpaid} * $form->{exchangerate}, 2);

  # store invoice total, this goes into ap table
  $form->{invtotal} = $form->{netamount} + $form->{total_tax};

  # amount for total AP
  $form->{payables} = $form->{invtotal};

  $form->{datepaid} = $form->{transdate} unless ($form->{datepaid});
  my $datepaid = ($form->{invpaid} != 0) ? $form->{datepaid} : undef;

  # update exchangerate
  if (($form->{currency} ne $form->{defaultcurrency}) && !$exchangerate) {
    $form->update_exchangerate($dbh, $form->{currency}, $form->{transdate}, 0,
                               $form->{exchangerate});
  }

  my ($query, $sth);

  if (!$payments_only) {
    # if we have an id delete old records
    if ($form->{id}) {

      # delete detail records
      $query = qq|DELETE FROM acc_trans WHERE trans_id = ?|;
      do_query($form, $dbh, $query, $form->{id});

    } else {
      my $uid = rand() . time;

      $uid .= $form->{login};

      $uid = substr($uid, 2, 75);

      $query =
        qq|INSERT INTO ap (invnumber, employee_id) | .
        qq|VALUES (?, (SELECT e.id FROM employee e WHERE e.login = ?))|;
      do_query($form, $dbh, $query, $uid, $form->{login});

      $query = qq|SELECT a.id FROM ap a
                  WHERE a.invnumber = ?|;
      ($form->{id}) = selectrow_query($form, $dbh, $query, $uid);
    }

    $form->{invnumber} = $form->{id} unless $form->{invnumber};

    $query = qq|UPDATE ap SET
                invnumber = ?, transdate = ?, ordnumber = ?, vendor_id = ?, taxincluded = ?,
                amount = ?, duedate = ?, paid = ?, datepaid = ?, netamount = ?,
                curr = ?, notes = ?, department_id = ?, storno = ?, storno_id = ?
               WHERE id = ?|;
    my @values = ($form->{invnumber}, conv_date($form->{transdate}),
                  $form->{ordnumber}, conv_i($form->{vendor_id}),
                  $form->{taxincluded} ? 't' : 'f', $form->{invtotal},
                  conv_date($form->{duedate}), $form->{invpaid},
                  conv_date($datepaid), $form->{netamount},
                  $form->{currency}, $form->{notes},
                  conv_i($form->{department_id}), $form->{storno},
                  $form->{storno_id}, $form->{id});
    do_query($form, $dbh, $query, @values);

    # add individual transactions
    for $i (1 .. $form->{rowcount}) {
      if ($form->{"amount_$i"} != 0) {
        my $project_id;
        $project_id = conv_i($form->{"project_id_$i"});
        $taxkey = $form->{AP_amounts}{"amount_$i"}{taxkey};

        # insert detail records in acc_trans
        $query =
          qq|INSERT INTO acc_trans | .
          qq|  (trans_id, chart_id, amount, transdate, project_id, taxkey)| .
          qq|VALUES (?, (SELECT c.id FROM chart c WHERE c.accno = ?), | .
          qq|  ?, ?, ?, ?)|;
        @values = ($form->{id}, $form->{AP_amounts}{"amount_$i"},
                   $form->{"amount_$i"}, conv_date($form->{transdate}),
                   $project_id, $taxkey);
        do_query($form, $dbh, $query, @values);

        if ($form->{"tax_$i"} != 0) {
          # insert detail records in acc_trans
          $query =
            qq|INSERT INTO acc_trans (trans_id, chart_id, amount, transdate, | .
            qq|  project_id, taxkey) | .
            qq|VALUES (?, (SELECT c.id FROM chart c WHERE c.accno = ?), | .
            qq|  ?, ?, ?, ?)|;
          @values = ($form->{id}, $form->{AP_amounts}{"tax_$i"},
                     $form->{"tax_$i"}, conv_date($form->{transdate}),
                     $project_id, $taxkey);
          do_query($form, $dbh, $query, @values);
        }

      }
    }

    # add payables
    $query =
      qq|INSERT INTO acc_trans (trans_id, chart_id, amount, transdate, taxkey) | .
      qq|VALUES (?, (SELECT id FROM chart WHERE accno = ?), ?, ?, | .
      qq|        (SELECT taxkey_id FROM chart WHERE accno = ?))|;
    @values = ($form->{id}, $form->{AP_amounts}{payables}, $form->{payables},
               conv_date($form->{transdate}), $form->{AP_amounts}{payables});
    do_query($form, $dbh, $query, @values);
  }

  # if there is no amount but a payment record a payable
  if ($form->{amount} == 0 && $form->{invtotal} == 0) {
    $form->{payables} = $form->{invpaid};
  }

  # add paid transactions
  for my $i (1 .. $form->{paidaccounts}) {
    if ($form->{"paid_$i"} != 0) {
      my $project_id = conv_i($form->{"paid_project_id_$i"});

      $exchangerate = 0;
      if ($form->{currency} eq $form->{defaultcurrency}) {
        $form->{"exchangerate_$i"} = 1;
      } else {
        $exchangerate              = $form->check_exchangerate($myconfig, $form->{currency}, $form->{"datepaid_$i"}, 'sell');
        $form->{"exchangerate_$i"} = $exchangerate || $form->parse_amount($myconfig, $form->{"exchangerate_$i"});
      }
      $form->{"AP_paid_$i"} =~ s/\"//g;

      # get paid account

      ($form->{AP}{"paid_$i"}) = split(/--/, $form->{"AP_paid_$i"});
      $form->{"datepaid_$i"} = $form->{transdate}
        unless ($form->{"datepaid_$i"});

      # if there is no amount and invtotal is zero there is no exchangerate
      if ($form->{amount} == 0 && $form->{invtotal} == 0) {
        $form->{exchangerate} = $form->{"exchangerate_$i"};
      }

      $amount =
        $form->round_amount($form->{"paid_$i"} * $form->{exchangerate} * -1,
                            2);
      if ($form->{payables}) {
        $query =
          qq|INSERT INTO acc_trans (trans_id, chart_id, amount, transdate, project_id, taxkey) | .
          qq|VALUES (?, (SELECT id FROM chart WHERE accno = ?), ?, ?, ?, | .
          qq|        (SELECT taxkey_id FROM chart WHERE accno = ?))|;
        @values = ($form->{id}, $form->{AP}{payables}, $amount,
                   conv_date($form->{"datepaid_$i"}), $project_id,
                   $form->{AP}{payables});
        do_query($form, $dbh, $query, @values);
      }
      $form->{payables} = $amount;

      # add payment
      $query =
        qq|INSERT INTO acc_trans (trans_id, chart_id, amount, transdate, source, memo, project_id, taxkey) | .
        qq|VALUES (?, (SELECT id FROM chart WHERE accno = ?), ?, ?, ?, ?, ?, | .
        qq|        (SELECT taxkey_id FROM chart WHERE accno = ?))|;
      @values = ($form->{id}, $form->{AP}{"paid_$i"}, $form->{"paid_$i"},
                 conv_date($form->{"datepaid_$i"}), $form->{"source_$i"},
                 $form->{"memo_$i"}, $project_id, $form->{AP}{"paid_$i"});
      do_query($form, $dbh, $query, @values);

      # add exchange rate difference
      $amount =
        $form->round_amount($form->{"paid_$i"} *
                            ($form->{"exchangerate_$i"} - 1), 2);
      if ($amount != 0) {
        $query =
          qq|INSERT INTO acc_trans (trans_id, chart_id, amount, transdate, fx_transaction, cleared, project_id, taxkey) | .
          qq|VALUES (?, (SELECT id FROM chart WHERE accno = ?), ?, ?, 't', 'f', ?, | .
          qq|        (SELECT taxkey_id FROM chart WHERE accno = ?))|;
        @values = ($form->{id}, $form->{AP}{"paid_$i"}, $amount,
                   conv_date($form->{"datepaid_$i"}), $project_id,
                   $form->{AP}{"paid_$i"});
        do_query($form, $dbh, $query, @values);
      }

      # exchangerate gain/loss
      $amount =
        $form->round_amount($form->{"paid_$i"} *
                            ($form->{exchangerate} -
                             $form->{"exchangerate_$i"}), 2);

      if ($amount != 0) {
        $query =
          qq|INSERT INTO acc_trans (trans_id, chart_id, amount, transdate, fx_transaction, cleared, project_id, taxkey) | .
          qq|VALUES (?, (SELECT id FROM chart WHERE accno = ?), ?, ?, 't', 'f', ?, | .
          qq|        (SELECT taxkey_id FROM chart WHERE accno = ?))|;
        @values = ($form->{id}, ($amount > 0) ?
                   $form->{fxgain_accno} : $form->{fxloss_accno},
                   $amount, conv_date($form->{"datepaid_$i"}), $project_id,
                   ($amount > 0) ?
                   $form->{fxgain_accno} : $form->{fxloss_accno});
        do_query($form, $dbh, $query, @values);
      }

      # update exchange rate record
      if (($form->{currency} ne $form->{defaultcurrency}) && !$exchangerate) {
        $form->update_exchangerate($dbh, $form->{currency},
                                   $form->{"datepaid_$i"},
                                   0, $form->{"exchangerate_$i"});
      }
    }
  }

  if ($payments_only) {
    $query = qq|UPDATE ap SET paid = ? WHERE id = ?|;
    do_query($form, $dbh, $query, $form->{invpaid}, conv_i($form->{id}));
  }

  my $rc = 1;
  if (!$provided_dbh) {
    $dbh->commit();
    $dbh->disconnect();
  }

  $main::lxdebug->leave_sub();

  return $rc;
}

sub delete_transaction {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig, $form, $spool) = @_;

  # connect to database
  my $dbh = $form->dbconnect_noauto($myconfig);

  my $query = qq|DELETE FROM ap WHERE id = ?|;
  do_query($form, $dbh, $query, $form->{id});

  $query = qq|DELETE FROM acc_trans WHERE trans_id = ?|;
  do_query($form, $dbh, $query, $form->{id});

  # commit and redirect
  my $rc = $dbh->commit;
  $dbh->disconnect;

  $main::lxdebug->leave_sub();

  return $rc;
}

sub ap_transactions {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig, $form) = @_;

  # connect to database
  my $dbh = $form->dbconnect($myconfig);

  my $query =
    qq|SELECT a.id, a.invnumber, a.transdate, a.duedate, a.amount, a.paid, | .
    qq|  a.ordnumber, v.name, a.invoice, a.netamount, a.datepaid, a.notes, | .
    qq|  a.globalproject_id, | .
    qq|  pr.projectnumber AS globalprojectnumber, | .
    qq|  e.name AS employee | .
    qq|FROM ap a | .
    qq|JOIN vendor v ON (a.vendor_id = v.id) | .
    qq|LEFT JOIN employee e ON (a.employee_id = e.id) | .
    qq|LEFT JOIN project pr ON (a.globalproject_id = pr.id) |;

  my $where = qq| WHERE COALESCE(storno, false) != true |;
  my @values;

  if ($form->{vendor_id}) {
    $where .= " AND a.vendor_id = ?";
    push(@values, $form->{vendor_id});
  } elsif ($form->{vendor}) {
    $where .= " AND v.name ILIKE ?";
    push(@values, $form->like($form->{vendor}));
  }
  if ($form->{department}) {
    my ($null, $department_id) = split /--/, $form->{department};
    $where .= " AND a.department_id = ?";
    push(@values, $department_id);
  }
  if ($form->{invnumber}) {
    $where .= " AND a.invnumber ILIKE ?";
    push(@values, $form->like($form->{invnumber}));
  }
  if ($form->{ordnumber}) {
    $where .= " AND a.ordnumber ILIKE ?";
    push(@values, $form->like($form->{ordnumber}));
  }
  if ($form->{notes}) {
    $where .= " AND lower(a.notes) LIKE ?";
    push(@values, $form->like($form->{notes}));
  }
  if ($form->{project_id}) {
    $where .=
      qq|AND ((a.globalproject_id = ?) OR EXISTS | .
      qq|  (SELECT * FROM invoice i | .
      qq|   WHERE i.project_id = ? AND i.trans_id = a.id))|;
    push(@values, $form->{project_id}, $form->{project_id});
  }

  if ($form->{transdatefrom}) {
    $where .= " AND a.transdate >= ?";
    push(@values, $form->{transdatefrom});
  }
  if ($form->{transdateto}) {
    $where .= " AND a.transdate <= ?";
    push(@values, $form->{transdateto});
  }
  if ($form->{open} || $form->{closed}) {
    unless ($form->{open} && $form->{closed}) {
      $where .= " AND a.amount <> a.paid" if ($form->{open});
      $where .= " AND a.amount = a.paid"  if ($form->{closed});
    }
  }

  if ($where) {
#     substr($where, 0, 4) = "WHERE";
    $query .= $where;
  }

  my @a = (transdate, invnumber, name);
  push @a, "employee" if $self->{l_employee};
  my $sortdir   = $form->{sortdir} ? 'ASC' : 'DESC';
  my $sortorder = join(', ', map { "$_ $sortdir" } @a);

  if (grep({ $_ eq $form->{sort} }
           qw(transdate id invnumber ordnumber name netamount tax amount
              paid datepaid due duedate notes employee))) {
    $sortorder = $form->{sort} . " $sortdir";
  }

  $query .= " ORDER BY $sortorder";

  my $sth = $dbh->prepare($query);
  $sth->execute(@values) ||
    $form->dberror($query . " (" . join(", ", @values) . ")");

  $form->{AP} = [];
  while (my $ap = $sth->fetchrow_hashref(NAME_lc)) {
    push @{ $form->{AP} }, $ap;
  }

  $sth->finish;
  $dbh->disconnect;

  $main::lxdebug->leave_sub();
}

sub get_transdate {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig, $form) = @_;

  # connect to database
  my $dbh = $form->dbconnect($myconfig);

  my $query =
    "SELECT COALESCE(" .
    "  (SELECT transdate FROM ap WHERE id = " .
    "    (SELECT MAX(id) FROM ap) LIMIT 1), " .
    "  current_date)";
  ($form->{transdate}) = $dbh->selectrow_array($query);

  $dbh->disconnect;

  $main::lxdebug->leave_sub();
}

sub _delete_payments {
  $main::lxdebug->enter_sub();

  my ($self, $form, $dbh) = @_;

  my @delete_oids;

  # Delete old payment entries from acc_trans.
  my $query =
    qq|SELECT oid
       FROM acc_trans
       WHERE (trans_id = ?) AND fx_transaction

       UNION

       SELECT at.oid
       FROM acc_trans at
       LEFT JOIN chart c ON (at.chart_id = c.id)
       WHERE (trans_id = ?) AND (c.link LIKE '%AP_paid%')|;
  push @delete_oids, selectall_array_query($form, $dbh, $query, conv_i($form->{id}), conv_i($form->{id}));

  $query =
    qq|SELECT at.oid
       FROM acc_trans at
       LEFT JOIN chart c ON (at.chart_id = c.id)
       WHERE (trans_id = ?)
         AND ((c.link = 'AP') OR (c.link LIKE '%:AP') OR (c.link LIKE 'AP:%'))
       ORDER BY at.oid
       OFFSET 1|;
  push @delete_oids, selectall_array_query($form, $dbh, $query, conv_i($form->{id}));

  if (@delete_oids) {
    $query = qq|DELETE FROM acc_trans WHERE oid IN (| . join(", ", @delete_oids) . qq|)|;
    do_query($form, $dbh, $query);
  }

  $main::lxdebug->leave_sub();
}

sub post_payment {
  $main::lxdebug->enter_sub();

  my ($self, $myconfig, $form, $locale) = @_;

  # connect to database, turn off autocommit
  my $dbh = $form->dbconnect_noauto($myconfig);

  my (%payments, $old_form, $row, $item, $query, %keep_vars);

  $old_form = save_form();

  # Delete all entries in acc_trans from prior payments.
  $self->_delete_payments($form, $dbh);

  # Save the new payments the user made before cleaning up $form.
  my $payments_re = '^datepaid_\d+$|^memo_\d+$|^source_\d+$|^exchangerate_\d+$|^paid_\d+$|^paid_project_id_\d+$|^AP_paid_\d+$|^paidaccounts$';
  map { $payments{$_} = $form->{$_} } grep m/$payments_re/, keys %{ $form };

  # Clean up $form so that old content won't tamper the results.
  %keep_vars = map { $_, 1 } qw(login password id);
  map { delete $form->{$_} unless $keep_vars{$_} } keys %{ $form };

  # Retrieve the invoice from the database.
  $form->create_links('AP', $myconfig, 'vendor', $dbh);

  # Restore the payment options from the user input.
  map { $form->{$_} = $payments{$_} } keys %payments;

  # Set up the content of $form in the way that AR::post_transaction() expects.

  $self->setup_form($form);

  ($form->{defaultcurrency}) = selectrow_query($form, $dbh, qq|SELECT curr FROM defaults|);
  $form->{defaultcurrency}   = (split m/:/, $form->{defaultcurrency})[0];

  $form->{exchangerate}      = $form->format_amount($myconfig, $form->{exchangerate});

  # Get the AP accno.
  $query =
    qq|SELECT c.accno
       FROM acc_trans at
       LEFT JOIN chart c ON (at.chart_id = c.id)
       WHERE (trans_id = ?)
         AND ((c.link = 'AP') OR (c.link LIKE '%:AP') OR (c.link LIKE 'AP:%'))
       ORDER BY at.oid
       LIMIT 1|;

  ($form->{APselected}) = selectfirst_array_query($form, $dbh, $query, conv_i($form->{id}));

  # Post the new payments.
  $self->post_transaction($myconfig, $form, $dbh, 1);

  restore_form($old_form);

  my $rc = $dbh->commit();
  $dbh->disconnect();

  $main::lxdebug->leave_sub();

  return $rc;
}

sub setup_form {
  $main::lxdebug->enter_sub();

  my ($self, $form) = @_;

  my ($exchangerate, $i, $j, $k, $key, $akey, $ref, $index, $taxamount, $totalamount);

  # forex
  $form->{forex} = $form->{exchangerate};
  $exchangerate = ($form->{exchangerate}) ? $form->{exchangerate} : 1;

  foreach $key (keys %{ $form->{AP_links} }) {
    foreach $ref (@{ $form->{AP_links}{$key} }) {
      if ($key eq "AP_paid") {
        $form->{"select$key"} .= "<option value=\"$ref->{accno}\">$ref->{accno}--$ref->{description}</option>\n";
      } else {
        $form->{"select$key"} .= "<option value=\"$ref->{accno}--$ref->{tax_id}\">$ref->{accno}--$ref->{description}</option>\n";
      }
    }

    $form->{$key} = $form->{"select$key"};

    # if there is a value we have an old entry
    $j = 0;
    $k = 0;

    for $i (1 .. scalar @{ $form->{acc_trans}{$key} }) {

      if ($key eq "AP_paid") {
        $j++;
        $form->{"AP_paid_$j"}         = "$form->{acc_trans}{$key}->[$i-1]->{accno}--$form->{acc_trans}{$key}->[$i-1]->{description}";
        $form->{"paid_$j"}            = $form->{acc_trans}{$key}->[$i - 1]->{amount};
        $form->{"datepaid_$j"}        = $form->{acc_trans}{$key}->[$i - 1]->{transdate};
        $form->{"source_$j"}          = $form->{acc_trans}{$key}->[$i - 1]->{source};
        $form->{"memo_$j"}            = $form->{acc_trans}{$key}->[$i - 1]->{memo};

        $form->{"exchangerate_$i"}    = $form->{acc_trans}{$key}->[$i - 1]->{exchangerate};
        $form->{"forex_$j"}           = $form->{"exchangerate_$i"};
        $form->{"AP_paid_$j"}         = $form->{acc_trans}{$key}->[$i-1]->{accno};
        $form->{"paid_project_id_$j"} = $form->{acc_trans}{$key}->[$i - 1]->{project_id};
        $form->{paidaccounts}++;

      } else {
        $akey = $key;
        $akey =~ s/AP_//;

        if (($key eq "AP_tax") || ($key eq "AR_tax")) {
          $form->{"${key}_$form->{acc_trans}{$key}->[$i-1]->{accno}"}  = "$form->{acc_trans}{$key}->[$i-1]->{accno}--$form->{acc_trans}{$key}->[$i-1]->{description}";
          $form->{"${akey}_$form->{acc_trans}{$key}->[$i-1]->{accno}"} = $form->round_amount($form->{acc_trans}{$key}->[$i - 1]->{amount} / $exchangerate, 2);

          if ($form->{"$form->{acc_trans}{$key}->[$i-1]->{accno}_rate"} > 0) {
            $totaltax += $form->{"${akey}_$form->{acc_trans}{$key}->[$i-1]->{accno}"};
          } else {
            $totalwithholding += $form->{"${akey}_$form->{acc_trans}{$key}->[$i-1]->{accno}"};
            $withholdingrate  += $form->{"$form->{acc_trans}{$key}->[$i-1]->{accno}_rate"};
          }

          $index                 = $form->{acc_trans}{$key}->[$i - 1]->{index};
          $form->{"tax_$index"}  = $form->{acc_trans}{$key}->[$i - 1]->{amount} * -1;
          $totaltax             += $form->{"tax_$index"};

        } else {
          $k++;
          $form->{"${akey}_$k"} = $form->round_amount($form->{acc_trans}{$key}->[$i - 1]->{amount} / $exchangerate, 2);

          if ($akey eq 'amount') {
            $form->{rowcount}++;
            $form->{"${akey}_$i"} *= -1;
            $totalamount          += $form->{"${akey}_$i"};
            $form->{taxrate}       = $form->{acc_trans}{$key}->[$i - 1]->{rate};

            $form->{"projectnumber_$k"}    = "$form->{acc_trans}{$key}->[$i-1]->{projectnumber}";
            $form->{"oldprojectnumber_$k"} = $form->{"projectnumber_$k"};
            $form->{"project_id_$k"}       = "$form->{acc_trans}{$key}->[$i-1]->{project_id}";
          }

          $form->{"${key}_$k"} = "$form->{acc_trans}{$key}->[$i-1]->{accno}--$form->{acc_trans}{$key}->[$i-1]->{description}";

          my $q_description    = quotemeta($form->{acc_trans}{$key}->[$i-1]->{description});
          $form->{"select${key}"} =~
            m/<option value=\"
                ($form->{acc_trans}{$key}->[$i-1]->{accno}--[^\"]*)
              \">
              $form->{acc_trans}{$key}->[$i-1]->{accno}
              --
              ${q_description}
              <\/option>\n/x;
          $form->{"${key}_$k"} = $1;

          if ($akey eq "AP") {
            $form->{APselected} = $form->{acc_trans}{$key}->[$i-1]->{accno};

          } elsif ($akey eq 'amount') {
            $form->{"${key}_$k"}   = $form->{acc_trans}{$key}->[$i-1]->{accno} . "--" . $form->{acc_trans}{$key}->[$i-1]->{id};
            $form->{"taxchart_$k"} = $form->{acc_trans}{$key}->[$i-1]->{id}    . "--" . $form->{acc_trans}{$key}->[$i-1]->{rate};
          }
        }
      }
    }
  }

  $form->{taxincluded}  = $taxincluded if ($form->{id});
  $form->{paidaccounts} = 1            if not defined $form->{paidaccounts};

  if ($form->{taxincluded} && $form->{taxrate} && $totalamount) {
    # add tax to amounts and invtotal
    for $i (1 .. $form->{rowcount}) {
      $taxamount            = ($totaltax + $totalwithholding) * $form->{"amount_$i"} / $totalamount;
      $tax                  = $form->round_amount($taxamount, 2);
      $diff                += ($taxamount - $tax);
      $form->{"amount_$i"} += $form->{"tax_$i"};
    }

    $form->{amount_1} += $form->round_amount($diff, 2);
  }

  $taxamount        = $form->round_amount($taxamount, 2);
  $form->{invtotal} = $totalamount + $totaltax;

  $main::lxdebug->leave_sub();
}

sub storno {
  $main::lxdebug->enter_sub();

  my ($self, $form, $myconfig, $id) = @_;

  my ($query, $new_id, $storno_row, $acc_trans_rows);
  my $dbh = $form->get_standard_dbh($myconfig);

  $query = qq|SELECT nextval('glid')|;
  ($new_id) = selectrow_query($form, $dbh, $query);

  $query = qq|SELECT * FROM ap WHERE id = ?|;
  $storno_row = selectfirst_hashref_query($form, $dbh, $query, $id);

  $storno_row->{id}         = $new_id;
  $storno_row->{storno_id}  = $id;
  $storno_row->{storno}     = 't';
  $storno_row->{invnumber}  = 'Storno-' . $storno_row->{invnumber};
  $storno_row->{amount}    *= -1;
  $storno_row->{netamount} *= -1;
  $storno_row->{paid}       = $storno_row->{amount};

  delete @$storno_row{qw(itime mtime)};

  $query = sprintf 'INSERT INTO ap (%s) VALUES (%s)', join(', ', keys %$storno_row), join(', ', map '?', values %$storno_row);
  do_query($form, $dbh, $query, (values %$storno_row));

  $query = qq|UPDATE ap SET paid = amount + paid, storno = 't' WHERE id = ?|;
  do_query($form, $dbh, $query, $id);

  # now copy acc_trans entries
  $query = qq|SELECT a.*, c.link FROM acc_trans a LEFT JOIN chart c ON a.chart_id = c.id WHERE a.trans_id = ? ORDER BY a.oid|;
  my $rowref = selectall_hashref_query($form, $dbh, $query, $id); 

  # kill all entries containing payments, which are the last 2n rows, of which the last has link =~ /paid/
  while ($rowref->[-1]{link} =~ /paid/) {
    splice(@$rowref, -2);
  }

  for my $row (@$rowref) {
    delete @$row{qw(itime mtime link)};
    $query = sprintf 'INSERT INTO acc_trans (%s) VALUES (%s)', join(', ', keys %$row), join(', ', map '?', values %$row);
    $row->{trans_id}   = $new_id;
    $row->{amount}    *= -1;
    do_query($form, $dbh, $query, (values %$row));
  }

  $dbh->commit;

  $main::lxdebug->leave_sub();
}

1;

