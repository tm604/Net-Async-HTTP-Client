#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008-2011 -- leonerd@leonerd.org.uk

package Net::Async::HTTP::Protocol;

use strict;
use warnings;

our $VERSION = '0.09';

use Carp;

use base qw( IO::Async::Protocol::Stream );

use HTTP::Response;

my $CRLF = "\x0d\x0a"; # More portable than \r\n

=head1 NAME

C<Net::Async::HTTP::Protocol> - HTTP client protocol handler

=head1 DESCRIPTION

This class provides a connection to a single HTTP server, and is used
internally by L<Net::Async::HTTP>. It is not intended for general use.

=cut

sub on_read
{
   my $self = shift;
   my ( $buffref, $closed ) = @_;

   if( my $on_read = shift @{ $self->{on_read_queue} } ) {
      return $on_read;
   }

   # Reinvoked after switch back to baseline, but may be idle again
   return if $closed or !length $$buffref;

   croak "Spurious on_read of connection while idle\n";
}

sub request
{
   my $self = shift;
   my %args = @_;

   my $on_header = $args{on_header} or croak "Expected 'on_header' as a CODE ref";
   my $on_error  = $args{on_error}  or croak "Expected 'on_error' as a CODE ref";
   
   my $req = $args{request};
   ref $req and $req->isa( "HTTP::Request" ) or croak "Expected 'request' as a HTTP::Request reference";

   my $request_body = $args{request_body};

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

      my $header = HTTP::Response->parse( $1 );

      my $on_body_chunk = $on_header->( $header );

      my $code = $header->code;

      # RFC 2616 says "HEAD" does not have a body, nor do any 1xx codes, nor
      # 204 (No Content) nor 304 (Not Modified)
      if( $method eq "HEAD" or $code =~ m/^1..$/ or $code eq "204" or $code eq "304" ) {
         $on_body_chunk->();
         return undef; # Finished
      }

      my $transfer_encoding = $header->header( "Transfer-Encoding" );
      my $content_length = $header->content_length;

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

                  $on_body_chunk->();
                  return undef; # Finished
               }
            }

            # Chunk is followed by a CRLF, which isn't counted in the length;
            if( defined $chunk_length and length( $$buffref ) >= $chunk_length + 2 ) {
               # Chunk body
               my $chunk = substr( $$buffref, 0, $chunk_length, "" );
               undef $chunk_length;

               unless( $$buffref =~ s/^$CRLF// ) {
                  $on_error->( "Chunk of size $chunk_length wasn't followed by CRLF" );
                  $self->close;
               }

               $on_body_chunk->( $chunk );

               return 1;
            }

            $on_error->( "Connection closed while awaiting chunk" ) if $closed;
            return 0;
         };
      }
      elsif( defined $content_length ) {
         if( $content_length == 0 ) {
            $on_body_chunk->();
            return undef; # Finished
         }

         return sub {
            my ( $self, $buffref, $closed ) = @_;

            # This will truncate it if the server provided too much
            my $content = substr( $$buffref, 0, $content_length, "" );

            $on_body_chunk->( $content );

            $content_length -= length $content;

            if( $content_length == 0 ) {
               $on_body_chunk->();
               return undef;
            }

            $on_error->( "Connection closed while awaiting body" ) if $closed;
            return 0;
         };
      }
      else {
         return sub {
            my ( $self, $buffref, $closed ) = @_;

            $on_body_chunk->( $$buffref );
            $$buffref = "";

            return 0 unless $closed;

            $on_body_chunk->();
            # $self already closed
            return undef;
         };
      }
   };

   # HTTP::Request is silly and uses "\n" as a separator. We must tell it to
   # use the correct RFC 2616-compliant CRLF sequence.
   $self->write( $req->as_string( $CRLF ) );

   $self->write( $request_body ) if $request_body;

   push @{ $self->{on_read_queue} }, $on_read;
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>
