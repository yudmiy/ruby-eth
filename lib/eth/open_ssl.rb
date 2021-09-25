# originally lifted from https://github.com/lian/bitcoin-ruby
# thanks to everyone there for figuring this out

module Eth
  class OpenSsl
    extend FFI::Library

    if FFI::Platform.windows?
      ffi_lib 'libeay32', 'ssleay32'
    else
      ffi_lib 'ssl'
    end

    NID_secp256k1 = 714
    POINT_CONVERSION_COMPRESSED = 2
    POINT_CONVERSION_UNCOMPRESSED = 4

    # OpenSSL 1.1.0 version as a numerical version value as defined in:
    # https://www.openssl.org/docs/man1.1.0/man3/OpenSSL_version.html
    VERSION_1_1_0_NUM = 0x10100000

    # OpenSSL 1.1.0 engine constants, taken from:
    # https://github.com/openssl/openssl/blob/2be8c56a39b0ec2ec5af6ceaf729df154d784a43/include/openssl/crypto.h
    OPENSSL_INIT_ENGINE_RDRAND = 0x00000200
    OPENSSL_INIT_ENGINE_DYNAMIC = 0x00000400
    OPENSSL_INIT_ENGINE_CRYPTODEV = 0x00001000
    OPENSSL_INIT_ENGINE_CAPI = 0x00002000
    OPENSSL_INIT_ENGINE_PADLOCK = 0x00004000
    OPENSSL_INIT_ENGINE_ALL_BUILTIN = (
      OPENSSL_INIT_ENGINE_RDRAND |
      OPENSSL_INIT_ENGINE_DYNAMIC |
      OPENSSL_INIT_ENGINE_CRYPTODEV |
      OPENSSL_INIT_ENGINE_CAPI |
      OPENSSL_INIT_ENGINE_PADLOCK
    )

    # OpenSSL 1.1.0 load strings constant, taken from:
    # https://github.com/openssl/openssl/blob/c162c126be342b8cd97996346598ecf7db56130f/include/openssl/ssl.h
    OPENSSL_INIT_LOAD_SSL_STRINGS = 0x00200000

    # This is the very first function we need to use to determine what version
    # of OpenSSL we are interacting with.
    begin
      attach_function :OpenSSL_version_num, [], :ulong
    rescue FFI::NotFoundError
      attach_function :SSLeay, [], :long
    end

    # Returns the version of SSL present.
    #
    # @return [Integer] version number as an integer.
    def self.version
      if self.respond_to?(:OpenSSL_version_num)
        OpenSSL_version_num()
      else
        SSLeay()
      end
    end

    if version >= VERSION_1_1_0_NUM
      # Initialization procedure for the library was changed in OpenSSL 1.1.0
      attach_function :OPENSSL_init_ssl, [:uint64, :pointer], :int
    else
      attach_function :SSL_library_init, [], :int
      attach_function :ERR_load_crypto_strings, [], :void
      attach_function :SSL_load_error_strings, [], :void
    end

    attach_function :RAND_poll, [], :int
    attach_function :BN_CTX_free, [:pointer], :int
    attach_function :BN_CTX_new, [], :pointer
    attach_function :BN_add, [:pointer, :pointer, :pointer], :int
    attach_function :BN_bin2bn, [:pointer, :int, :pointer], :pointer
    attach_function :BN_bn2bin, [:pointer, :pointer], :int
    attach_function :BN_cmp, [:pointer, :pointer], :int
    attach_function :BN_dup, [:pointer], :pointer
    attach_function :BN_free, [:pointer], :int
    attach_function :BN_mod_inverse, [:pointer, :pointer, :pointer, :pointer], :pointer
    attach_function :BN_mod_mul, [:pointer, :pointer, :pointer, :pointer, :pointer], :int
    attach_function :BN_mod_sub, [:pointer, :pointer, :pointer, :pointer, :pointer], :int
    attach_function :BN_mul_word, [:pointer, :int], :int
    attach_function :BN_new, [], :pointer
    attach_function :BN_num_bits, [:pointer], :int
    attach_function :BN_rshift, [:pointer, :pointer, :int], :int
    attach_function :BN_set_word, [:pointer, :int], :int
    attach_function :ECDSA_SIG_free, [:pointer], :void
    attach_function :ECDSA_do_sign, [:pointer, :uint, :pointer], :pointer
    attach_function :EC_GROUP_get_curve_GFp, [:pointer, :pointer, :pointer, :pointer, :pointer], :int
    attach_function :EC_GROUP_get_degree, [:pointer], :int
    attach_function :EC_GROUP_get_order, [:pointer, :pointer, :pointer], :int
    attach_function :EC_KEY_free, [:pointer], :int
    attach_function :EC_KEY_get0_group, [:pointer], :pointer
    attach_function :EC_KEY_new_by_curve_name, [:int], :pointer
    attach_function :EC_KEY_set_conv_form, [:pointer, :int], :void
    attach_function :EC_KEY_set_private_key, [:pointer, :pointer], :int
    attach_function :EC_KEY_set_public_key,  [:pointer, :pointer], :int
    attach_function :EC_POINT_free, [:pointer], :int
    attach_function :EC_POINT_mul, [:pointer, :pointer, :pointer, :pointer, :pointer, :pointer], :int
    attach_function :EC_POINT_new, [:pointer], :pointer
    attach_function :EC_POINT_set_compressed_coordinates_GFp, [:pointer, :pointer, :pointer, :int, :pointer], :int
    attach_function :i2o_ECPublicKey, [:pointer, :pointer], :uint

    class << self
      def BN_num_bytes(ptr)
        (BN_num_bits(ptr) + 7) / 8
      end

      def sign_compact(hash, private_key, public_key_hex)
        private_key = [private_key].pack("H*") if private_key.bytesize >= 64
        pubkey_compressed = false

        init_ffi_ssl
        eckey = EC_KEY_new_by_curve_name(NID_secp256k1)
        priv_key = BN_bin2bn(private_key, private_key.bytesize, BN_new())

        group, order, ctx = EC_KEY_get0_group(eckey), BN_new(), BN_CTX_new()
        EC_GROUP_get_order(group, order, ctx)

        pub_key = EC_POINT_new(group)
        EC_POINT_mul(group, pub_key, priv_key, nil, nil, ctx)
        EC_KEY_set_private_key(eckey, priv_key)
        EC_KEY_set_public_key(eckey, pub_key)

        signature = ECDSA_do_sign(hash, hash.bytesize, eckey)

        BN_free(order)
        BN_CTX_free(ctx)
        EC_POINT_free(pub_key)
        BN_free(priv_key)
        EC_KEY_free(eckey)

        buf, rec_id, head = FFI::MemoryPointer.new(:uint8, 32), nil, nil
        r, s = signature.get_array_of_pointer(0, 2).map{|i| BN_bn2bin(i, buf); buf.read_string(BN_num_bytes(i)).rjust(32, "\x00") }

        if signature.get_array_of_pointer(0, 2).all?{|i| BN_num_bits(i) <= 256 }
          4.times{|i|
            head = [ Eth.v_base + i ].pack("C")
            if public_key_hex == recover_public_key_from_signature(hash, [head, r, s].join, i, pubkey_compressed)
              rec_id = i; break
            end
          }
        end

        ECDSA_SIG_free(signature)

        [ head, [r,s] ].join if rec_id
      end

      def recover_public_key_from_signature(message_hash, signature, rec_id, is_compressed)
        return nil if rec_id < 0 or signature.bytesize != 65
        init_ffi_ssl

        signature = FFI::MemoryPointer.from_string(signature)
        r = BN_bin2bn(signature[1], 32, BN_new())
        s = BN_bin2bn(signature[33], 32, BN_new())

        _n, i = 0, rec_id / 2
        eckey = EC_KEY_new_by_curve_name(NID_secp256k1)

        EC_KEY_set_conv_form(eckey, POINT_CONVERSION_COMPRESSED) if is_compressed

        group = EC_KEY_get0_group(eckey)
        order = BN_new()
        EC_GROUP_get_order(group, order, nil)
        x = BN_dup(order)
        BN_mul_word(x, i)
        BN_add(x, x, r)

        field = BN_new()
        EC_GROUP_get_curve_GFp(group, field, nil, nil, nil)

        if BN_cmp(x, field) >= 0
          bn_free_each r, s, order, x, field
          EC_KEY_free(eckey)
          return nil
        end

        big_r = EC_POINT_new(group)
        EC_POINT_set_compressed_coordinates_GFp(group, big_r, x, rec_id % 2, nil)

        big_q = EC_POINT_new(group)
        n = EC_GROUP_get_degree(group)
        e = BN_bin2bn(message_hash, message_hash.bytesize, BN_new())
        BN_rshift(e, e, 8 - (n & 7)) if 8 * message_hash.bytesize > n

        ctx = BN_CTX_new()
        zero, rr, sor, eor = BN_new(), BN_new(), BN_new(), BN_new()
        BN_set_word(zero, 0)
        BN_mod_sub(e, zero, e, order, ctx)
        BN_mod_inverse(rr, r, order, ctx)
        BN_mod_mul(sor, s, rr, order, ctx)
        BN_mod_mul(eor, e, rr, order, ctx)
        EC_POINT_mul(group, big_q, eor, big_r, sor, ctx)
        EC_KEY_set_public_key(eckey, big_q)
        BN_CTX_free(ctx)

        bn_free_each r, s, order, x, field, e, zero, rr, sor, eor
        [big_r, big_q].each{|j| EC_POINT_free(j) }

        recover_public_hex eckey
      end

      def recover_compact(hash, signature)
        return false if signature.bytesize != 65

        version = signature.unpack('C')[0]

        # Version of signature should be 27 or 28, but 0 and 1 are also possible versions
        # which can show up in Ledger hardwallet signings
        if version < 27
          version += 27
        end

        v_base = Eth.replayable_v?(version) ? Eth.replayable_chain_id : Eth.v_base

        return false if version < v_base

        recover_public_key_from_signature(hash, signature, (version - v_base), false)
      end

      def init_ffi_ssl
        return if @ssl_loaded
        if version >= VERSION_1_1_0_NUM
          OPENSSL_init_ssl(
            OPENSSL_INIT_LOAD_SSL_STRINGS | OPENSSL_INIT_ENGINE_ALL_BUILTIN,
            nil
          )
        else
          SSL_library_init()
          ERR_load_crypto_strings()
          SSL_load_error_strings()
        end

        RAND_poll()
        @ssl_loaded = true
      end


      private

      def bn_free_each(*list)
        list.each{|j| BN_free(j) }
      end

      def recover_public_hex(eckey)
        length = i2o_ECPublicKey(eckey, nil)
        buf = FFI::MemoryPointer.new(:uint8, length)
        ptr = FFI::MemoryPointer.new(:pointer).put_pointer(0, buf)
        pub_hex = if i2o_ECPublicKey(eckey, ptr) == length
          buf.read_string(length).unpack("H*")[0]
        end

        EC_KEY_free(eckey)

        pub_hex
      end
    end

  end
end
