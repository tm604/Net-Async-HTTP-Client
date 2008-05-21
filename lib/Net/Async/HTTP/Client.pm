#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008 -- leonerd@leonerd.org.uk

package Net::Async::HTTP::Client;

use strict;

our $VERSION = '0.01';

use Carp;

use base qw( IO::Async::Sequencer );

use HTTP::Response;

my $CRLF = "\x0d\x0a"; # More portable than \r\n

=head1 NAME

C<Net::Async::HTTP::Client> - Asynchronous HTTP client

=head1 DESCRIPTION

This class provides a connection to a single HTTP server, and is used
internally by L<Net::Async::HTTP>. It is not intended for general use.

=cut

sub new
{
   my $class = shift;
   my %args = @_;

   $args{marshall_request} = \&marshall_request;
   $args{on_read}          = \&on_read;

   my $self = $class->SUPER::new( %args );

   return $self;
}

# For passing in to constructor
sub marshall_request
{
   my $self = shift;
   my ( $request ) = @_;

   # HTTP::Request is silly and uses "\n" as a separator. We must tell it to
   # use the correct RFC 2616-compliant CRLF sequence.
   return $request->as_string( $CRLF );
}

# For passing in to constructor
sub on_read
{
   my $self = shift;

   croak "Spurious on_read of connection while idle\n";
}

# Override
sub request
{
   my $self = shift;
   my %args = @_;

   my $on_response = $args{on_response} or croak "Expected 'on_response' as a CODE ref";
   my $on_error    = $args{on_error}    or croak "Expected 'on_error' as a CODE ref";
   
   my $req = $args{request};
   ref $req and $req->isa( "HTTP::Request" ) or croak "Expected 'request' as a HTTP::Request reference";

   my $method = $req->method;

   if( $method eq "POST" or $method eq "PUT" or length $req->content ) {
      $req->init_header( "Content-Length", length $req->content );
   }

   my $on_read = sub {
      my ( $self, $buffref, $closed ) = @_;

      unless( $$buffref =~ s/^(.*?$CRLF$CRLF)//s ) {
         $on_error->( "Connection closed while awaiting header" ) if $closed;
         return 0;
      }

      my $response_header = $1;
      my $response = HTTP::Response->parse( $response_header );

      my $code = $response->code;

      # RFC 2616 says "HEAD" does not have a body, nor do any 1xx codes, nor
      # 204 (No Content) nor 304 (Not Modified)
      if( $method eq "HEAD" or $code =~ m/^1..$/ or $code eq "204" or $code eq "304" ) {
         $on_response->( $response );
         return undef; # Finished
      }

      my $transfer_encoding = $response->header( "Transfer-Encoding" );
      my $content_length = $response->content_length;

      if( defined $transfer_encoding and $transfer_encoding eq "chunked" ) {
         my $chunk_length;

         return sub {
            my ( $self, $buffref, $closed ) = @_;

            if( !defined $chunk_length and $$buffref =~ s/^(.*?)$CRLF// ) {
               # Chunk header
               $chunk_length = hex( $1 );
               return 1 if $chunk_length;

               my $trailer = "";

               # Now the trailer
               return sub {
                  my ( $self, $buffref, $closed ) = @_;

                  $on_error->( "Connection closed while awaiting chunk trailer" ) if $closed;

                  $$buffref =~ s/^(.*)$CRLF// or return 0;
                  $trailer .= $1;

                  return 1 if length $1;

                  # TODO: Actually use the trailer

                  $on_response->( $response );
                  return undef; # Finished
               }
            }

            if( defined $chunk_length and length( $$buffref ) >= $chunk_length ) {
               # Chunk body
               my $chunk = substr( $$buffref, 0, $chunk_length, "" );
               undef $chunk_length;

               $response->add_content( $chunk );

               return 1;
            }

            $on_error->( "Connection closed while awaiting chunk" ) if $closed;
            return 0;
         };
      }
      elsif( defined $content_length ) {
         if( $content_length == 0 ) {
            $on_response->( $response );
            return undef; # Finished
         }

         return sub {
            my ( $self, $buffref, $closed ) = @_;

            if( length $$buffref >= $content_length ) {
               my $content = substr( $$buffref, 0, $content_length, "" );

               $response->content( $content );

               $on_response->( $response );
               return undef; # Finished
            }

            $on_error->( "Connection closed while awaiting body" ) if $closed;
            return 0;
         };
      }
      else {
         return sub {
            my ( $self, $buffref, $closed ) = @_;

            return 0 unless $closed;

            my $content = $$buffref;
            $$buffref = "";

            $response->content( $content );

            $on_response->( $response );
            # $self already closed
            return undef;
         };
      }
   };

   $self->SUPER::request(
      request => $req,
      on_read => $on_read,
   );
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>