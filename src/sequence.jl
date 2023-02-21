function Genome(sequence_dict::Dict{String, LongDNA{4}})
    seq = LongDNA{4}(undef, sum(length(s) for s in values(sequence_dict)))
    chrs = Dict{String, UnitRange}()
    si = 1
    for (name, sequence) in sequence_dict
        srange = si:si+length(sequence)-1
        seq[srange] = sequence
        push!(chrs, name=>srange)
        si = last(srange) + 1
    end
    return Genome(seq, chrs)
end
Genome(sequences::Vector{LongDNA{4}}, names::Vector{String}) = Genome(Dict(n=>s for (n,s) in zip(names, sequences)))
Genome(sequence::LongDNA{4}, name::String) = Genome([sequence], [name])
Genome(genome_file::String) = Genome(read_genomic_fasta(genome_file))

Base.length(genome::Genome) = length(genome.seq)
Base.getindex(genome::Genome, key::String) = view(genome.seq, genome.chroms[key])
Base.getindex(genome::Genome, key::Pair{String, UnitRange}) = view(genome[first(key)], last(key))
Base.getindex(genome::Genome, key::Interval{Nothing}) = view(genome[refname(key)], leftposition(key):rightposition(key))
Base.getindex(genome::Genome, key::Interval{Annotation}) = view(genome[refname(key)], leftposition(key):rightposition(key))

function nchromosome(genome::Genome)
    return length(genome.chroms)
end

function Base.iterate(genome::Genome)
    (chr, slice) = first(genome.chroms)
    ((chr, view(genome.seq, slice)), 1)
end

function Base.iterate(genome::Genome, state::Int)
    state += 1
    state > length(genome.chroms) && (return nothing)
    for (i, (chr, slice)) in enumerate(genome.chroms)
        (i == state) && (return ((chr, view(genome.seq, slice)), state))
    end
end

function Base.merge(genomes::Vector{Genome})
    length(genomes) == 1 && return genomes[1]
    merged = genomes[1]
    for genome in genomes[2:end]
        merged *= genome
    end
    return merged
end

function Base.:*(genome1::Genome, genome2::Genome)
    return Genome(genome1.seq*genome2.seq, merge(genome1.chroms, Dict(key=>(range .+ length(genome1)) for (key, range) in genome2.chroms)))
end

function Base.write(file::String, genome::Genome)
    write_genomic_fasta(Dict(chr=>seq for (chr, seq) in genome), file)
end

function read_genomic_fasta(fasta_file::String)
    genome::Dict{String, LongDNA{4}} = Dict()
    open(FASTA.Reader, fasta_file) do reader
        for record in reader
            genome[FASTA.identifier(record)] = FASTA.sequence(LongDNA{4}, record)
        end
    end
    return genome
end

function write_genomic_fasta(genome::Dict{String, T}, fasta_file::String) where T <: LongDNA{4}
    open(FASTA.Writer, fasta_file) do writer
        for (chr, seq) in genome
            write(writer, FASTA.Record(chr, seq))
        end
    end
end

function Sequences()
    Sequences(LongDNA{4}(""), UInt[], UnitRange{Int}[])
end

function Sequences(::Type{T}) where {T<:Union{String, UInt}}
    Sequences(LongDNA{4}(""), T[], UnitRange{Int}[])
end

function Sequences(seqs::Vector{LongDNA{4}}, seqnames::Vector{T}; sort_by_name=false) where T <: Union{UInt, String}
    (length(seqnames) == length(seqs)) || throw(AssertionError("number of names must match the number of sequences!"))
    (length(seqnames) == length(unique(seqnames))) || throw(AssertionError("names must be unique!"))
    ranges = Vector{UnitRange{Int}}(undef, length(seqs))
    seq = LongDNA{4}("")
    resize!(seq, sum(length(s) for s in seqs))
    current_range = 1:0
    for (i,s) in enumerate(seqs)
        current_range = last(current_range)+1:last(current_range)+length(s)
        seq[current_range] = s
        ranges[i] = current_range
    end
    seqs = Sequences(seq, seqnames, ranges)
    sort_by_name && sortbyname!(seqs)
    return seqs
end
Sequences(seqs::Vector{LongDNA{4}}) = Sequences(seqs, Vector{UInt}(1:length(seqs)))

function Sequences(file::String; is_reverse_complement=false, hash_id=true, sort_by_name=false)
    read_reads(file; is_reverse_complement=is_reverse_complement, hash_id=hash_id, sort_by_name=sort_by_name)
end

Sequences(genomes::Vector{Genome}) =
    Sequences([genome.seq for genome in genomes], UInt.(i for i in 1:length(genomes)), [i:i for i in 1:length(genomes)])

summarize(seqs::Sequences) = "$(typeof(seqs)) with $(length(seqs)) sequences on $(nread(seqs)) reads"
Base.show(io::IO, seqs::Sequences) = print(io, summarize(seqs))

Base.getindex(seqs::Sequences, index::Int) = view(seqs.seq, seqs.ranges[index])
function Base.getindex(seqs::Sequences, range::Union{StepRange{Int, Int}, UnitRange{Int}})
    mi, ma = first(minimum(seqs.ranges[range])), last(maximum(seqs.ranges[range]))
    Sequences(seqs.seq[mi:ma], seqs.tempnames[range], [r .- (mi-1) for r in seqs.ranges[range]])
end

Base.length(seqs::Sequences) = length(seqs.tempnames)
nread(seqs::Sequences) = length(unique(seqs.tempnames))
@inline Base.iterate(seqs::Sequences) = (view(seqs.seq, seqs.ranges[1]), 2)
@inline Base.iterate(seqs::Sequences, state::Int) = state > length(seqs.ranges) ? nothing : (view(seqs.seq, seqs.ranges[state]), state+1)
eachpair(seqs::Sequences) = partition(seqs, 2)
Base.empty!(seqs::Sequences) = (empty!(seqs.seq); empty!(seqs.tempnames); empty!(seqs.ranges))

function sortbyname!(seqs::Sequences{T}) where T <:Union{UInt, String}
    sortids = sortperm(seqs.tempnames)
    seqs.tempnames .= seqs.tempnames[sortids]
    seqs.ranges .= seqs.ranges[sortids]
    seqs
end

function BioSequences.reverse_complement!(seqs::Sequences{T}) where T <:Union{UInt, String}
    reverse_complement!(seqs.seq)
    seqs.ranges .= [(length(seqs.seq)-last(r)+1):(length(seqs.seq)-first(r)+1) for r in seqs.ranges]
    seqs
end

function Base.filter!(seqs::Sequences{T}, tempnames::Set{T}) where {T<:Union{String, UInt}}
    bitindex = (in).(seqs.tempnames, Ref(tempnames))
    n_seqs = sum(bitindex)
    seqs.ranges[1:n_seqs] = seqs.ranges[bitindex]
    seqs.tempnames[1:n_seqs] = seqs.tempnames[bitindex]
    resize!(seqs.ranges, n_seqs)
    resize!(seqs.tempnames, n_seqs)
end

function read_reads(file::String; is_reverse_complement=false, hash_id=true, sort_by_name=false)
    seqs::Sequences{hash_id ? UInt : String} = hash_id ? Sequences(UInt) : Sequences(String)
    is_fastq = any([endswith(file, ending) for ending in FASTQ_TYPES])
    data = UInt8[]
    current_range = 1:0
    lasti::Int = 0
    for (i, record) in enumerate(is_fastq ? eachfastqrecord(file) : eachfastarecord(file))
        id = hash_id ? hash(StringView(@view(record.data[record.identifier]))) : FASTX.identifier(record)
        s = @view(record.data[record.sequence])
        current_range = last(current_range)+1:last(current_range)+length(s)
        length(data) < last(current_range) && resize!(data, length(data)+max(1000000, last(current_range)-length(data)))
        if length(seqs.tempnames) < i
            resize!(seqs.tempnames, length(seqs.tempnames)+10000)
            resize!(seqs.ranges, length(seqs.ranges)+10000)
        end
        seqs.tempnames[i] = id
        seqs.ranges[i] = current_range
        data[current_range] .= s
        lasti = i
    end
    resize!(seqs.seq, last(current_range))
    resize!(data, last(current_range))
    seqs.seq[:] = LongDNA{4}(data)
    resize!(seqs.tempnames, lasti)
    resize!(seqs.ranges, lasti)
    is_reverse_complement && reverse_complement!(seqs)
    sort_by_name && sortbyname!(seqs)
    return seqs
end

function Base.write(fname::String, seqs::Sequences{T}) where T
    rec = FASTA.Record()
    FASTA.Writer(GzipCompressorStream(open(fname, "w"); level=2)) do writer
        for (i,s) in enumerate(seqs)
            rec = FASTA.Record(T <: UInt ? string(seqs.tempnames[i]) : seqs.tempnames[i], s)
            write(writer, rec)
        end
    end
end

struct MatchIterator
    sq::Union{ExactSearchQuery,ApproximateSearchQuery}
    seq::LongDNA{4}
    max_dist::Int
end
MatchIterator(test_sequence::LongDNA{4}, seq::LongDNA{4}; k=0) =
    MatchIterator(k>0 ? ApproximateSearchQuery(test_sequence) : ExactSearchQuery(test_sequence), seq, k)
function Base.iterate(m::MatchIterator, state=1)
    current_match = m.max_dist > 0 ? findnext(m.sq, m.max_dist, m.seq, state) : findnext(m.sq, m.seq, state)
    isnothing(current_match) && return nothing
    current_match, last(current_match)
end
Base.eachmatch(test_sequence::LongDNA{4}, seq::LongDNA{4}; k=0) = MatchIterator(test_sequence, seq; k=k)

struct GenomeMatchIterator
    mi_f::MatchIterator
    mi_r::MatchIterator
    chroms::Dict{String, UnitRange}
end
GenomeMatchIterator(test_sequence::LongDNA{4}, genome::Genome; k=0) =
    GenomeMatchIterator(MatchIterator(test_sequence, genome.seq; k=k), MatchIterator(reverse_complement(test_sequence), genome.seq; k=k), genome.chroms)
function Base.iterate(gmi::GenomeMatchIterator, (state,rev)=(1,false))
    i = iterate(rev ? gmi.mi_r : gmi.mi_f, state)
    isnothing(i) && return rev ? nothing : iterate(gmi, (1,true))
    for (chr, r) in gmi.chroms
        (first(r) <= first(first(i)) <= last(r)) && return Interval(chr, first(i) .- first(r), rev ? STRAND_NEG : STRAND_POS), (last(i), rev)
    end
end
Base.eachmatch(test_sequence::LongDNA{4}, genome::Genome; k=0) = GenomeMatchIterator(test_sequence, genome; k=k)

function Base.collect(m::GenomeMatchIterator)
    re = Interval{Nothing}[]
    for match in m
        push!(re, match)
    end
    return re
end
function Base.collect(m::MatchIterator)
    re = UnitRange{Int}[]
    for match in m
        push!(re, match)
    end
    return re
end

function nucleotidedistribution(seqs::Sequences; normalize=true, align=:left)
    align in (:left, :right) || throw(AssertionError("align has to be :left or :right"))
    max_length = maximum(length(r) for r in seqs.ranges)
    count = Dict{DNA, Vector{Float64}}(
        DNA_A=>zeros(max_length), DNA_T=>zeros(max_length),
        DNA_G=>zeros(max_length), DNA_C=>zeros(max_length),
        DNA_N=>zeros(max_length)
    )
    index::BitVector = falses(length(seqs.seq))
    for n in keys(count)
        index .= seqs.seq .== n
        for r in seqs.ranges
            for (ii::Int, i::Int) in enumerate(r)
                index[i] && (count[n][align == :right ? ii+(max_length-length(r)) : ii] += 1.0)
            end
        end
    end
    if normalize
        for c in values(count)
            c ./= length(seqs)
        end
    end
    return count
end

information_content(m::Matrix{Float64}; n=Inf) = m .* (2 .- ([-1 * sum(x > 0 ? x * log2(x) : 0 for x in r) for r in eachrow(m)] .+ (3/(2*log(2)*n))))

function Logo(seqs::Sequences; align=:left)
    nc = nucleotidedistribution(seqs; align=align)
    m = hcat(nc[DNA_A], nc[DNA_T], nc[DNA_G], nc[DNA_C])
    Logo(length(seqs), information_content(m; n=length(seqs)), [DNA_A, DNA_T, DNA_G, DNA_C])
end

consensusbits(logo::Logo) = round.(maximum.(eachrow(logo.weights)); digits=2)
consensusseq(logo::Logo) = LongDNA{4}(logo.alphabet[argmax.(eachrow(logo.weights))])

summarize(logo::Logo) = "Consensus sequence of logo of $(logo.nseqs) sequences of length $(size(logo.weights, 1)):\n\n" *
    "sequence: " * string(consensusseq(logo)) * "\nbits    : " * join(round.(Int, consensusbits(logo)))

Base.show(io::IO, logo::Logo) = print(io, summarize(logo))

mutable struct FASTQIterator
    reader::FASTQ.Reader
    record::FASTQ.Record
    stop::Union{Nothing,Int}
end

@inline Base.iterate(it::FASTQIterator, state=1) = (eof(it.reader) || (!isnothing(it.stop) && state>it.stop)) ? (close(it.reader); nothing) : (read!(it.reader, it.record), state+1)
eachfastqrecord(fname::String; stopat=nothing) = FASTQIterator(FASTQ.Reader(endswith(fname, ".gz") ? GzipDecompressorStream(open(fname)) : open(fname)), FASTQ.Record(), stopat)

mutable struct FASTAIterator
    reader::FASTA.Reader
    record::FASTA.Record
    stop::Union{Nothing,Int}
end

@inline Base.iterate(it::FASTAIterator, state=1) = (eof(it.reader) || (!isnothing(it.stop) && state>it.stop)) ? (close(it.reader); nothing) : (read!(it.reader, it.record), state+1)
eachfastarecord(fname::String; stopat=nothing) = FASTAIterator(FASTA.Reader(endswith(fname, ".gz") ? GzipDecompressorStream(open(fname)) : open(fname)), FASTA.Record(), stopat)