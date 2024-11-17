module pokemon_marketplace::main {
    use std::error;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::object::{Self, ExtendRef, Object};
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_token_objects::collection;
    use aptos_token_objects::token;
    use std::option;

    /// Error codes
    const ENOT_AUTHORIZED: u64 = 1;
    const EPOKEMON_NOT_EXIST: u64 = 2;
    const EPRICE_INVALID: u64 = 3;
    const EINSUFFICIENT_FUNDS: u64 = 4;
    const EINVALID_POKEMON_ID: u64 = 5;
    const EPOKEMON_ALREADY_LISTED: u64 = 6;

    const MAX_POKEMON: u64 = 16;

    // Collection constants
    const COLLECTION_NAME: vector<u8> = b"Pokemon Collection V1";
    const COLLECTION_DESCRIPTION: vector<u8> = b"A collection of unique Pokemon NFTs";
    const COLLECTION_URI: vector<u8> = b"https://xxplwdmjiahdwvjqlivi.supabase.co/storage/v1/object/public/pokemon-nfts/collection.svg";
    const SEED: vector<u8> = b"POKEMON_NFT_V1";

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Pokemon has key {
        name: String,
        description: String,
        pokemon_id: u64,
        price: u64,
        mutator_ref: token::MutatorRef,
        burn_ref: token::BurnRef,
        extend_ref: ExtendRef,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct PokemonURIs has key {
        uris: vector<String>,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct MarketplaceData has key {
        mint_events: EventHandle<MintPokemonEvent>,
        sale_events: EventHandle<PokemonSoldEvent>,
        listing_events: EventHandle<PokemonListedEvent>,
        signer_cap: ExtendRef,
    }

    #[event]
    struct MintPokemonEvent has drop, store {
        pokemon_id: u64,
        creator: address,
        token_name: String,
        price: u64,
    }

    #[event]
    struct PokemonSoldEvent has drop, store {
        pokemon_id: u64,
        seller: address,
        buyer: address,
        price: u64,
    }

    #[event]
    struct PokemonListedEvent has drop, store {
        pokemon_id: u64,
        seller: address,
        price: u64,
    }

    fun init_module(creator: &signer) {
        let creator_addr = signer::address_of(creator);
        
        // Create the main object that will store marketplace data
        let constructor_ref = object::create_named_object(creator, SEED);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let marketplace_signer = object::generate_signer(&constructor_ref);

        // Create the collection
        collection::create_unlimited_collection(
            &marketplace_signer,
            string::utf8(COLLECTION_DESCRIPTION),
            string::utf8(COLLECTION_NAME),
            option::none(),
            string::utf8(COLLECTION_URI),
        );

        // Initialize URIs
        move_to(&marketplace_signer, PokemonURIs {
            uris: initialize_pokemon_uris(),
        });

        // Initialize marketplace data with correct event handles
        move_to(&marketplace_signer, MarketplaceData {
            mint_events: account::new_event_handle<MintPokemonEvent>(creator),
            sale_events: account::new_event_handle<PokemonSoldEvent>(creator),
            listing_events: account::new_event_handle<PokemonListedEvent>(creator),
            signer_cap: extend_ref,
        });
    }

    fun initialize_pokemon_uris(): vector<String> {
        let uris = vector::empty<String>();
        let base_uri = b"https://xxplwdmjiahdwvjqlivi.supabase.co/storage/v1/object/public/pokemon-nfts/";
        
        let i = 0;
        while (i < MAX_POKEMON) {
            let uri = string::utf8(base_uri);
            string::append(&mut uri, string::utf8(vector::empty<u8>()));
            string::append_utf8(&mut uri, vector::singleton((i + 86) as u8));
            string::append(&mut uri, string::utf8(b".svg"));
            vector::push_back(&mut uris, uri);
            i = i + 1;
        };
        
        uris
    }

    public entry fun create_pokemon(
        creator: &signer,
        pokemon_id: u64,
        name: String,
        description: String,
        price: u64,
    ) acquires PokemonURIs, MarketplaceData {
        // Validate inputs
        assert!(pokemon_id > 0 && pokemon_id <= MAX_POKEMON, error::invalid_argument(EINVALID_POKEMON_ID));
        assert!(price > 0, error::invalid_argument(EPRICE_INVALID));

        let collection_addr = object::create_object_address(&@pokemon_marketplace, SEED);
        let uris = &borrow_global<PokemonURIs>(collection_addr).uris;
        let uri = *vector::borrow(uris, (pokemon_id - 1) as u64);

        // Create token
        let constructor_ref = token::create_named_token(
            creator,
            string::utf8(COLLECTION_NAME),
            description,
            name,
            option::none(),
            uri,
        );

        let token_signer = object::generate_signer(&constructor_ref);
        
        // Create Pokemon object
        let pokemon = Pokemon {
            name,
            description,
            pokemon_id,
            price,
            mutator_ref: token::generate_mutator_ref(&constructor_ref),
            burn_ref: token::generate_burn_ref(&constructor_ref),
            extend_ref: object::generate_extend_ref(&constructor_ref),
        };

        move_to(&token_signer, pokemon);

        // Emit mint event
        let market_data = borrow_global_mut<MarketplaceData>(collection_addr);
        event::emit_event(
            &mut market_data.mint_events,
            MintPokemonEvent {
                pokemon_id,
                creator: signer::address_of(creator),
                token_name: name,
                price,
            },
        );
    }

    public entry fun buy_pokemon(
        buyer: &signer,
        pokemon_obj: Object<Pokemon>,
    ) acquires Pokemon, MarketplaceData {
        let pokemon_addr = object::object_address(&pokemon_obj);
        let pokemon = borrow_global<Pokemon>(pokemon_addr);
        
        // Verify pokemon exists and price
        assert!(object::is_owner(pokemon_obj, signer::address_of(buyer)), error::not_found(EPOKEMON_NOT_EXIST));
        assert!(coin::balance<AptosCoin>(signer::address_of(buyer)) >= pokemon.price, 
               error::invalid_argument(EINSUFFICIENT_FUNDS));
        
        let seller = object::owner(pokemon_obj);

        // Transfer payment
        coin::transfer<AptosCoin>(buyer, seller, pokemon.price);

        // Emit sale event
        let collection_addr = object::create_object_address(&@pokemon_marketplace, SEED);
        let market_data = borrow_global_mut<MarketplaceData>(collection_addr);
        event::emit_event(
            &mut market_data.sale_events,
            PokemonSoldEvent {
                pokemon_id: pokemon.pokemon_id,
                seller,
                buyer: signer::address_of(buyer),
                price: pokemon.price,
            },
        );

        // Transfer Pokemon
        object::transfer(buyer, pokemon_obj, signer::address_of(buyer));
    }

    public entry fun list_pokemon(
        seller: &signer,
        pokemon_obj: Object<Pokemon>,
        new_price: u64,
    ) acquires Pokemon, MarketplaceData {
        let pokemon_addr = object::object_address(&pokemon_obj);
        
        // Verify ownership and price
        assert!(object::is_owner(pokemon_obj, signer::address_of(seller)), 
               error::permission_denied(ENOT_AUTHORIZED));
        assert!(new_price > 0, error::invalid_argument(EPRICE_INVALID));

        let pokemon = borrow_global_mut<Pokemon>(pokemon_addr);
        assert!(pokemon.price == 0, error::invalid_argument(EPOKEMON_ALREADY_LISTED));
        
        // Update price
        pokemon.price = new_price;

        // Emit listing event
        let collection_addr = object::create_object_address(&@pokemon_marketplace, SEED);
        let market_data = borrow_global_mut<MarketplaceData>(collection_addr);
        event::emit_event(
            &mut market_data.listing_events,
            PokemonListedEvent {
                pokemon_id: pokemon.pokemon_id,
                seller: signer::address_of(seller),
                price: new_price,
            },
        );
    }

    #[view]
    public fun get_pokemon_price(pokemon_obj: Object<Pokemon>): u64 acquires Pokemon {
        let pokemon = borrow_global<Pokemon>(object::object_address(&pokemon_obj));
        pokemon.price
    }

    #[view]
    public fun get_pokemon_details(pokemon_obj: Object<Pokemon>): (u64, String, String, u64) acquires Pokemon {
        let pokemon = borrow_global<Pokemon>(object::object_address(&pokemon_obj));
        (
            pokemon.pokemon_id,
            pokemon.name,
            pokemon.description,
            pokemon.price
        )
    }
}