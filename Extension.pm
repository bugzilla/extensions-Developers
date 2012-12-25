# -*- Mode: perl; indent-tabs-mode: nil -*-
#
# The contents of this file are subject to the Mozilla Public
# License Version 1.1 (the "License"); you may not use this file
# except in compliance with the License. You may obtain a copy of
# the License at http://www.mozilla.org/MPL/
#
# Software distributed under the License is distributed on an "AS
# IS" basis, WITHOUT WARRANTY OF ANY KIND, either express or
# implied. See the License for the specific language governing
# rights and limitations under the License.
#
# The Original Code is the Developers Bugzilla Extension.
#
# The Initial Developer of the Original Code is Olav Vitters
# Portions created by the Initial Developer are Copyright (C) 2011 the
# Initial Developer. All Rights Reserved.
#
# Contributor(s):
#   Olav Vitters <olav@vitters.nl>

package Bugzilla::Extension::Developers;
use strict;
use base qw(Bugzilla::Extension);

# This code for this is in ./extensions/Developers/lib/Util.pm
use Bugzilla::Extension::Developers::Util;
use Bugzilla::Constants;

our $VERSION = '0.01';

BEGIN {
        *Bugzilla::Product::developers = \&developers;
        *Bugzilla::User::is_developer = \&is_developer;
}

# See the documentation of Bugzilla::Hook ("perldoc Bugzilla::Hook" 
# in the bugzilla directory) for a list of all available hooks.
sub install_update_db {
    my ($self, $args) = @_;

    _migrate_gnome_developers();
}

sub _migrate_gnome_developers {
    my $dbh = Bugzilla->dbh;

    # Create the global developer group if it doesn't yet exist
    my $dev_group = Bugzilla::Group->new({ name => 'developers' });
    return 1 if $dev_group;

    # Create product specific groups:
    foreach my $product (Bugzilla::Product->get_all) {
        my $group = Bugzilla::Group->new(
            { name => $product->name . '_developers' });
        if (!$group) {
            _create_developer($product);
        }
    }
}

sub object_end_of_create {
    my ($self, $args) = @_;

    my $class  = $args->{'class'};
    my $object = $args->{'object'};

    if ($class->isa('Bugzilla::Product')) {
        _create_developer($object);
    }
}

sub _create_developer {
    my $product = shift;

    # For every product in Bugzilla, create a group named like 
    # "<product_name>_developers". 
    # Every developer in the product should be made a member of this group.
    my $new_group = Bugzilla::Group->create({
        name        => $product->{'name'} . '_developers',
        description => $product->{'name'} . ' Developers',
        isactive    => 1,
        isbuggroup  => 1,
    });
 
    # The "<product name>_developers" group should be set to
    # "MemberControl: Shown, OtherControl: Shown" in the product's group controls.
    #
    # The "<product name>_developers" group should also be given editcomponents 
    # for the product.
    my $dbh = Bugzilla->dbh;
    $dbh->do('INSERT INTO group_control_map
              (group_id, product_id, entry, membercontrol,
               othercontrol, canedit, editcomponents)
              VALUES (?, ?, 0, ?, ?, 0, 1)',
              undef, ($new_group->id, $product->id, CONTROLMAPSHOWN,
                      CONTROLMAPSHOWN));

    # The group should be able to bless itself.
    $dbh->do('INSERT INTO group_group_map (grantor_id, member_id, grant_type)
                   VALUES (?,?,?)',
              undef, $new_group->id, $new_group->id, GROUP_BLESS);

    # The new <product_name>_developers groups should be automatically
    # made a member of the global developers group
    my $dev_group = Bugzilla::Group->new({ name => 'developers' });
    if (!$dev_group) {
        $dev_group = Bugzilla::Group->create({
            name        => 'developers',
            description => 'Developers',
            isbuggroup  => 1,
            isactive    => 1,
        });
    }

    $dbh->do('INSERT INTO group_group_map
              (member_id, grantor_id, grant_type)
              VALUES (?, ?, ?)',
             undef, ($new_group->id, $dev_group->id, GROUP_MEMBERSHIP));

    # The main "developers" group should be set to
    # "MemberControl: Shown, OtherControl: Shown" in the product's group controls.
    $dbh->do('INSERT INTO group_control_map
              (group_id, product_id, entry, membercontrol,
               othercontrol, canedit, editcomponents)
              VALUES (?, ?, 0, ?, ?, 0, 0)',
              undef, ($dev_group->id, $product->id, CONTROLMAPSHOWN, 
                      CONTROLMAPSHOWN));
}


sub object_before_delete {
    my ($self, $args) = @_;

    my $object = $args->{'object'};

    # Note that this is a made-up class, for this example.
    if ($object->isa('Bugzilla::Product')) {
        my $id = $object->id;
        _delete_developer($object);
    } 
}

sub _delete_developer {
    my $self = shift;

    my $dbh = Bugzilla->dbh;

    # Delete this product's developer group and its members
    my $group = Bugzilla::Group->new({ name => $self->name . '_developers' });
    if ($group) {
        $dbh->do('DELETE FROM user_group_map WHERE group_id = ?',
                  undef, $group->id);
        $dbh->do('DELETE FROM group_group_map 
                  WHERE grantor_id = ? OR member_id = ?',
                  undef, ($group->id, $group->id));
        $dbh->do('DELETE FROM bug_group_map WHERE group_id = ?',
                  undef, $group->id);
        $dbh->do('DELETE FROM group_control_map WHERE group_id = ?',
                  undef, $group->id);
        $dbh->do('DELETE FROM groups WHERE id = ?',
                  undef, $group->id);
    }
}

sub object_end_of_update {
    my ($self, $args) = @_;

    my ($object, $old_object, $changes) =
        @$args{qw(object old_object changes)};

    # Note that this is a made-up class, for this example.
    if ($object->isa('Bugzilla::Product')) {
        if (defined $changes->{'name'}) {
            my ($old, $new) = @{ $changes->{'name'} };
            _rename_developer($object, $old_object, $changes);
        }
    }
}

sub _rename_developer {
    my ($self, $old_self, $changes) = @_;

    my $developer_group = new Bugzilla::Group(
        { name => $old_self->name . "_developers" });
    my $new_group = new Bugzilla::Group(
        { name => $self->name . '_developers' });
    if ($developer_group && !$new_group) {
        $developer_group->set_name($self->name . "_developers");
        $developer_group->set_description($self->name . " Developers");
        $developer_group->update();
    }
}


sub developers {
    my ($self) = @_;

    if (!defined $self->{'developers'}) {
        $self->{'developers'} = [];

        my $group = Bugzilla::Group->new({ name => $self->name . '_developers' });
        $self->{developers} = $group ? $group->members_non_inherited : [];
    }

    return $self->{'developers'};
}


sub is_developer {
    my ($self, $product) = @_;

    if ($product) {
        # Given the only use of this is being passed bug.product_obj,
        # at the moment the performance of this should be fine.
        my $devs = $product->developers;
        my $is_dev = grep { $_->id == $self->id } @$devs;
        return $is_dev ? 1 : 0;
    }
    else {
        return $self->in_group("developers") ? 1 : 0;
    }

    return 0; 
}

__PACKAGE__->NAME;
