use 5.008001;
use strict;
use warnings;
no warnings 'once';

package MooX::Enumeration;

use Carp qw(croak);
use Scalar::Util qw(blessed);
use Sub::Util qw(set_subname);
use B qw(perlstring);

our $AUTHORITY = 'cpan:TOBYINK';
our $VERSION   = '0.002';

sub import {
	my $class  = shift;
	my $caller = caller;
	$class->setup_for($caller);
}

sub setup_for {
	my $class = shift;
	my ($target) = @_;
	
	my $orig = $Moo::MAKERS{$target}{exports}{has}
		or croak("$target doesn't have a `has` function");
	
	Moo::_install_tracked $target, has => sub {
		if (@_ % 2 == 0) {
			croak "Invalid options for attribute(s): even number of arguments expected, got " . scalar @_;
		}
		
		my ($attrs, %spec) = @_;
		$attrs = [$attrs] unless ref $attrs;
		for my $attr (@$attrs) {
			%spec = $class->process_spec($target, $attr, %spec);
			if (ref $spec{handles}) {
				my $handles = $spec{_orig_handles} = delete $spec{handles};
				$class->install_delegates($target, $attr, $spec{isa}, %$handles);
			}
			$orig->($attr, %spec);
		}
		return;
	};
}

sub process_spec {
	my $class = shift;
	my ($target, $attr, %spec) = @_;
	
	my @values;
	
	# Handle the type constraint stuff
	if (exists $spec{isa} and exists $spec{enum}) {
		croak "Cannot supply both the 'isa' and 'enum' options";
	}
	elsif (blessed $spec{isa} and $spec{isa}->isa('Type::Tiny::Enum')) {
		@values = @{ $spec{isa}->values };
	}
	elsif (exists $spec{enum}) {
		croak "Expected arrayref for enum" unless ref $spec{enum} eq 'ARRAY';
		@values = @{ delete $spec{enum} };
		require Type::Tiny::Enum;
		$spec{isa} = Type::Tiny::Enum->new(values => \@values);
	}
	else {
		# nothing to do
		return %spec;
	}
	
	# Canonicalize handles
	if (my $handles = $spec{handles}) {
		
		if (!ref $handles and $handles eq 1) {
			$handles = +{ map +( "is_$_" => [ "is", $_ ] ), @values };
		}
		
		if (ref $handles eq 'ARRAY') {
			$handles = +{ map ref($_)?@$_:($_=>[split/_/,$_,2]), @$handles };
		}
		
		if (ref $handles eq 'HASH') {
			for my $k (keys %$handles) {
				next if ref $handles->{$k};
				$handles->{$k}=[split/_/,$handles->{$k},2];
			}
		}
		
		$spec{handles} = $handles;
	}
	
	# Install moosify stuff
	if (ref $spec{moosify} eq 'CODE') {
		$spec{moosify} = [$spec{moosify}];
	}
	push @{ $spec{moosify} ||= [] }, sub {
		my $spec = shift;
		require MooseX::Enumeration;
		require MooseX::Enumeration::Meta::Attribute::Native::Trait::Enumeration;
		push @{ $spec->{traits} ||= [] }, 'Enumeration';
		$spec->{handles} ||= $spec->{_orig_handles} if $spec->{_orig_handles};
	};
	
	return %spec;
}

sub install_delegates {
	my $class  = shift;
	my ($target, $attr, $type, %delegates) = @_;
	
	for my $method (keys %delegates) {
		my ($delegate_type, @delegate_params) = @{ $delegates{$method} };
		my $builder = "build_${delegate_type}_delegate";
		
		no strict 'refs';
		*{"${target}::${method}"} =
			set_subname "${target}::${method}",
			$class->$builder($target, $method, $attr, $type, @delegate_params);
	}
}

sub build_is_delegate {
	my $class  = shift;
	my ($target, $method, $attr, $type, $match) = @_;
	
	if (ref $match) {
		require match::simple;
		return eval sprintf(
			'sub { %s; match::simple::match($_[0]{%s}, $match) }',
			$class->_build_throw_args($method, 0),
			perlstring($attr),
		);
	}
	elsif ($type->check($match)) {
		return eval sprintf(
			'sub { %s; $_[0]{%s} eq %s }',
			$class->_build_throw_args($method, 0),
			perlstring($attr),
			perlstring($match),
		);
	}
	else {
		croak sprintf "Attribute $attr cannot be %s", perlstring($match);
	}
}

sub build_assign_delegate {
	my $class  = shift;
	my ($target, $method, $attr, $type, $newvalue, $match) = @_;

	croak sprintf "Attribute $attr cannot be %s", perlstring($newvalue)
		unless $type->check($newvalue);
	
	my $err = 'Method %s cannot be called when attribute %s has value %s';

	if (ref $match) {
		require match::simple;
		return eval sprintf(
			'sub { %s; return $_[0] if $_[0]{%s} eq %s; match::simple::match($_[0]{%s}, $match) ? ($_[0]{%s}=%s) : Carp::croak(sprintf %s, %s, %s, $_[0]{%s}); $_[0] }',
			$class->_build_throw_args($method, 0),
			perlstring($attr),
			perlstring($newvalue),
			perlstring($attr),
			perlstring($attr),
			perlstring($newvalue),
			perlstring($err),
			perlstring($method),
			perlstring($attr),
			perlstring($attr),
		);
	}
	elsif (defined $match) {
		return eval sprintf(
			'sub { %s; return $_[0] if $_[0]{%s} eq %s; ($_[0]{%s} eq %s) ? ($_[0]{%s}=%s) : Carp::croak(sprintf %s, %s, %s, $_[0]{%s}); $_[0] }',
			$class->_build_throw_args($method, 0),
			perlstring($attr),
			perlstring($newvalue),
			perlstring($attr),
			perlstring($match),
			perlstring($attr),
			perlstring($newvalue),
			perlstring($err),
			perlstring($method),
			perlstring($attr),
			perlstring($attr),
		);
	}
	else {
		return eval sprintf(
			'sub { %s; $_[0]{%s} = %s; $_[0] }',
			$class->_build_throw_args($method, 0),
			perlstring($attr),
			perlstring($newvalue),
		);
	}
}

sub _build_throw_args {
	my $class = shift;
	my ($method, $n) = @_;
	sprintf(
		'Carp::croak(sprintf "Method %%s expects %%d arguments", %s, %d) if @_ != %d;',
		perlstring($method),
		$n,
		$n+1,
	);
}

1;

__END__

=pod

=encoding utf-8

=head1 NAME

MooX::Enumeration - shortcuts for working with enum attributes in Moo

=head1 SYNOPSIS

Given this class:

   package MyApp::Result {
      use Moo;
      use Types::Standard qw(Enum);
      has status => (
         is        => "rw",
         isa       => Enum[qw/ pass fail /],
      );
   }

It's quite common to do this kind of thing:

   if ( $result->status eq "pass" ) { ... }

But if you're throwing strings around, it can be quite easy to mistype
them:

   if ( $result->status eq "apss" ) { ... }

And the comparison silently fails. Instead, let's define the class like
this:

   package MyApp::Result {
      use Moo;
      use MooX::Enumeration;
      use Types::Standard qw(Enum);
      has status => (
         is        => "rw",
         isa       => Enum[qw/ pass fail /],
         handles   => [qw/ is_pass is_fail /],
      );
   }

So you can use the class like this:

   if ( $result->is_pass ) { ... }

Yay!

=head1 DESCRIPTION

This is a Moo implementation of L<MooseX::Enumeration>. All the features
from the Moose version should work here.

Passing C<< traits => ["Enumeration"] >> to C<has> is not needed with
MooX::Enumeration. This module's magic is automatically applied to all
attributes with a L<Type::Tiny::Enum> type constraint.

Simple example:

   package MyClass {
      use Moo;
      use MooX::Enumeration;
      
      has xyz => (is => "ro", enum => [qw/foo bar baz/], handles => 1);
   }

C<< MyClass->new(xyz => "quux") >> will throw an error.

Objects of the class will have C<< $object->is_foo >>, C<< $object->is_bar >>,
and C<< $object->is_baz >> methods.

For more details of method delegation, see L<MooseX::Enumeration>.

=head1 BUGS

Please report any bugs to
L<http://rt.cpan.org/Dist/Display.html?Queue=MooX-Enumeration>.

=head1 SEE ALSO

L<MooseX::Enumeration>.

L<Type::Tiny::Enum>.

L<Moo>.

=head1 AUTHOR

Toby Inkster E<lt>tobyink@cpan.orgE<gt>.

=head1 COPYRIGHT AND LICENCE

This software is copyright (c) 2018 by Toby Inkster.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=head1 DISCLAIMER OF WARRANTIES

THIS PACKAGE IS PROVIDED "AS IS" AND WITHOUT ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, WITHOUT LIMITATION, THE IMPLIED WARRANTIES OF
MERCHANTIBILITY AND FITNESS FOR A PARTICULAR PURPOSE.

