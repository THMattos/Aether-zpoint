// ============================================================
// Aether Script — Example 02
// Aether-Shield: Post-Quantum Cryptography with ZPF Entropy
// File: examples/aether_shield.as
// ============================================================
//
// Demonstrates:
//   - Zero-Point Fluctuation entropy harvesting
//   - CRYSTALS-Kyber key encapsulation (NIST PQC standard)
//   - CRYSTALS-Dilithium digital signatures
//   - End-to-end encrypted quantum-safe messaging
//   - Resistance to both classical and quantum adversaries
//
// Security claim:
//   An adversary with a fault-tolerant quantum computer running
//   Shor's algorithm CANNOT break Aether-Shield communications.
//   Security reduces to hardness of Module-LWE (algebraic lattices).
// ============================================================

using Security.AetherShield
using Security.ZPCEntropy
using Quantum.Core
using Classical.Bridge

// ── Security Level Configuration ─────────────────────────────

const SHIELD_LEVEL: KyberLevel    = KyberLevel.K768    // NIST Level 3
const SIG_LEVEL:    DilithiumLevel = DilithiumLevel.D3 // ~128-bit post-quantum
const ENTROPY_POOL: int            = 128               // bytes of ZPF entropy


// ── ZPC Entropy Harvesting ────────────────────────────────────
// True randomness from quantum vacuum fluctuations.
// NOT pseudo-random. NOT seeded. Fundamentally stochastic.

@zpc_stabilized(tolerance=0.0001)   // Strict tolerance for security use
quantum fn harvest_true_entropy(n_bytes: int) -> bytes:
    let n_bits: int  = n_bytes * 8
    let q: QReg[512] = allocate_qreg(n_bits)

    // Each qubit begins as |0⟩
    // Hadamard creates perfect superposition: |+⟩ = (|0⟩+|1⟩)/√2
    // Measurement outcome is irreducibly random (Born rule)
    for i in 0..n_bits:
        hadamard(q[i])

    // Collapse all qubits — each collapses independently
    // No correlation between qubits (all initialized fresh)
    let raw_bits: List<bit> = measure_all(q)

    // Von Neumann extractor: removes any residual bias
    // (pairs bits: 01→0, 10→1, 00/11→discard)
    let debiased: bytes = VonNeumann.extract(raw_bits)

    return debiased


// ── Key Generation ────────────────────────────────────────────
// Generate a full Aether-Shield identity keypair.
// Kyber for encryption, Dilithium for signatures.

type ShieldIdentity = {
    kyber_pk:      KyberPublicKey,       // Share with others (for encryption TO you)
    kyber_sk:      KyberSecretKey,       // Keep secret (to decrypt messages)
    dilithium_pk:  DilithiumPublicKey,   // Share with others (for signature verification)
    dilithium_sk:  DilithiumSecretKey,   // Keep secret (to sign messages)
    entropy_seed:  bytes,                // ZPF entropy used in generation (audit trail)
    created_at:    int,
}

fn generate_identity(label: str = "aether-user") -> ShieldIdentity:
    // All randomness derives from ZPF — no classical PRNG involved
    let entropy: bytes = harvest_true_entropy(ENTROPY_POOL)
    println(f"🔬 ZPF entropy harvested: {entropy.len() * 8} bits from quantum vacuum")

    // HKDF expands entropy into multiple seeds
    let kyber_seed:     bytes = hkdf(entropy, info=b"kyber-keygen")
    let dilithium_seed: bytes = hkdf(entropy, info=b"dilithium-keygen")

    // Lattice-based key generation
    let (kyber_pk, kyber_sk)         = Kyber.keygen(kyber_seed, level=SHIELD_LEVEL)
    let (dilithium_pk, dilithium_sk) = Dilithium.keygen(dilithium_seed, level=SIG_LEVEL)

    println(f"✅ Identity generated for '{label}'")
    println(f"   Kyber public key:     {kyber_pk.fingerprint()}")
    println(f"   Dilithium public key: {dilithium_pk.fingerprint()}")

    return ShieldIdentity {
        kyber_pk,
        kyber_sk,
        dilithium_pk,
        dilithium_sk,
        entropy_seed: entropy.sha3_256(),    // Store hash, not raw entropy
        created_at:   unix_now(),
    }


// ── Sealed Message Type ───────────────────────────────────────

type SealedMessage = {
    kyber_ciphertext: bytes,        // Encapsulated shared secret (Kyber KEM)
    aes_nonce:        bytes,        // GCM nonce (96 bits)
    aes_ciphertext:   bytes,        // Encrypted payload (AES-256-GCM)
    aes_tag:          bytes,        // GCM authentication tag
    signature:        DilithiumSig, // Sender's signature over full message
    sender_pk:        DilithiumPublicKey,
    protocol_version: str,
}


// ── Encryption (Seal) ─────────────────────────────────────────
// Encrypt a message to recipient_identity using Aether-Shield.
// Security: IND-CCA2 under MLWE assumption.

fn seal_message(
    plaintext:    bytes,
    recipient_pk: KyberPublicKey,
    sender_id:    ShieldIdentity,
    aad:          bytes = b""      // Additional authenticated data (optional)
) -> SealedMessage:

    // ── 1. Kyber KEM: encapsulate a shared secret
    //   Produces: ciphertext (sent to recipient) + shared_secret (local)
    let (kyber_ct, shared_secret) = Kyber.encapsulate(recipient_pk)

    // ── 2. Derive AES-256 key via HKDF-SHA3
    let aes_key: bytes = hkdf(
        ikm  = shared_secret,
        salt = harvest_true_entropy(32),   // Fresh ZPF salt each message
        info = b"aether-shield-aes-v1",
        length = 32
    )

    // ── 3. Encrypt payload with AES-256-GCM
    let nonce: bytes          = harvest_true_entropy(12)   // 96-bit ZPF nonce
    let (aes_ct, tag): (bytes, bytes) = AES256GCM.encrypt(
        plaintext = plaintext,
        key       = aes_key,
        nonce     = nonce,
        aad       = aad
    )

    // ── 4. Sign the sealed message with Dilithium
    //   Signature covers: kyber_ct || nonce || aes_ct || tag || aad
    let sig_payload: bytes = concat(kyber_ct, nonce, aes_ct, tag, aad)
    let signature: DilithiumSig = Dilithium.sign(
        message   = sig_payload,
        secret_key = sender_id.dilithium_sk
    )

    return SealedMessage {
        kyber_ciphertext: kyber_ct,
        aes_nonce:        nonce,
        aes_ciphertext:   aes_ct,
        aes_tag:          tag,
        signature:        signature,
        sender_pk:        sender_id.dilithium_pk,
        protocol_version: "aether-shield/1.0",
    }


// ── Decryption (Open) ─────────────────────────────────────────
// Decrypt and verify an Aether-Shield sealed message.
// Returns Err if signature invalid, ciphertext tampered, or key mismatch.

type OpenResult = Ok<bytes> | Err<ShieldError>

fn open_message(
    sealed:       SealedMessage,
    recipient_id: ShieldIdentity,
    aad:          bytes = b""
) -> OpenResult:

    // ── 1. Verify Dilithium signature FIRST (fail fast on tampering)
    let sig_payload: bytes = concat(
        sealed.kyber_ciphertext,
        sealed.aes_nonce,
        sealed.aes_ciphertext,
        sealed.aes_tag,
        aad
    )

    if not Dilithium.verify(sig_payload, sealed.signature, sealed.sender_pk):
        return Err(ShieldError.SIGNATURE_INVALID)

    // ── 2. Kyber KEM: decapsulate to recover shared secret
    let shared_secret: bytes = Kyber.decapsulate(
        ciphertext = sealed.kyber_ciphertext,
        secret_key = recipient_id.kyber_sk
    )

    // ── 3. Re-derive AES key (deterministic from shared secret)
    let aes_key: bytes = hkdf(
        ikm    = shared_secret,
        info   = b"aether-shield-aes-v1",
        length = 32
    )

    // ── 4. Decrypt and authenticate
    let result: OpenResult = AES256GCM.decrypt(
        ciphertext = sealed.aes_ciphertext,
        key        = aes_key,
        nonce      = sealed.aes_nonce,
        tag        = sealed.aes_tag,
        aad        = aad
    )

    return result


// ── Demo Execution ────────────────────────────────────────────

fn main() -> int:
    println("🛡️  Aether-Shield — Post-Quantum Cryptography Demo")
    println("   Entropy source: Zero-Point Fluctuations (quantum vacuum)")
    println("   Algorithm:      CRYSTALS-Kyber 768 + Dilithium 3")
    println("")

    // Generate two identities
    let alice: ShieldIdentity = generate_identity("alice")
    let bob:   ShieldIdentity = generate_identity("bob")
    println("")

    // Alice encrypts a message to Bob
    let plaintext: bytes = b"The quantum future is now. — Alice"
    let sealed: SealedMessage = seal_message(
        plaintext    = plaintext,
        recipient_pk = bob.kyber_pk,
        sender_id    = alice
    )
    println(f"📨 Alice sealed message ({sealed.aes_ciphertext.len()} bytes ciphertext)")

    // Bob decrypts and verifies
    match open_message(sealed, bob):
        Ok(msg):
            println(f"✅ Bob opened message: \"{msg.to_str()}\"")
            println(f"   Sender verified:    {alice.dilithium_pk.fingerprint()}")
        Err(e):
            println(f"❌ Decryption failed: {e}")
            return 1

    println("")
    println("🔐 Quantum-safe exchange complete.")
    println("   Shor's algorithm: ineffective against lattice-based cryptography.")
    return 0
