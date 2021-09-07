function prepare_data(data_path::String, genome::Genome; files=FastqgzFiles)
    files = files(data_path)
    trimmed = trim_fastp(files)
    bams = align_mem(trimmed, genome;)
    compute_coverage(bams)
end

function de_genes(features::Features, coverages::Vector{Coverage}, conditions::Dict{String, UnitRange{Int}}, results_path::String; between_conditions=nothing, add_keys=["BaseValueFrom", "BaseValueTo", "LogFoldChange", "PValue", "AdjustedPValue"])
    between_conditions = isnothing(between_conditions) ? combinations(collect(conditions), 2) : [((a,conditions[a]), (b,conditions[b])) for (a,b) in between_conditions]
    for ((name1, range1), (name2, range2)) in between_conditions
        annotate!(features, coverages[range1], coverages[range2])
        write(joinpath(results_path, name1 * "_vs_" * name2 * ".csv"), asdataframe(features, add_keys=add_keys))
    end
end

function feature_count(features::Features, coverages::Vector{Coverage}, conditions::Dict{String, UnitRange{Int}}, results_path::String; between_conditions=nothing)
    expnames = Dict{String,Vector{String}}()
    for (name, range) in conditions
        annotate!(features, coverages[range]; count_key="$name")
        expnames[name] = ["$name$i" for i in 1:length(range)]
    end
    write(joinpath(results_path, "all_counts.csv"), asdataframe(features; add_keys=vcat([val for val in values(expnames)]...)))
    if !isnothing(between_conditions)
        for (cond1, cond2) in between_conditions
            exps = [expnames[cond1]...,expnames[cond2]...]
            write(joinpath(results_path, "$(cond1)_vs_$cond2.csv"), asdataframe(features; add_keys=exps))
        end
    end
end

function feature_count(features::Features, bams::SingleTypeFiles, conditions::Dict{String, UnitRange{Int}}, results_path::String; between_conditions=nothing)
    expnames = Dict{String,Vector{String}}()
    mybams = copy(bams)
    for (name, range) in conditions
        mybams.list = bams[range]
        annotate!(features, mybams; count_key="$name")
        expnames[name] = ["$name$i" for i in 1:length(range)]
    end
    write(joinpath(results_path, "all_counts.csv"), asdataframe(features; add_keys=vcat([val for val in values(expnames)]...)))
    if !isnothing(between_conditions)
        for (cond1, cond2) in between_conditions
            exps = [expnames[cond1]...,expnames[cond2]...]
            write(joinpath(results_path, "$(cond1)_vs_$cond2.csv"), asdataframe(features; add_keys=exps))
        end
    end
end

function feature_ratio(features::Features, coverage_files::PairedSingleTypeFiles, results_file::String)
    result_string = "filename\t" * join([t for t in features.types], "\t") * "\n"
    split_features = split(features)
    for (file1,file2) in coverage_files
        coverage = Coverage(file1,file2)
        result_string *= basename(file1)[1:end-11] * "\t" * join([covratio(f, coverage) for f in split_features], "\t") * "\n"
    end
    write(results_file, result_string)
end

function unmapped_reads(bams::SingleTypeFiles)
    for bam_file in bams
        record = BAM.Record()
        reader = BAM.Reader(open(bam_file))
        writer = GzipCompressorStream(open(joinpath(dirname(bam_file), "unmapped_" * basename(bam_file)[1:end-3] * "fasta.gz"), "w"))
        while !eof(reader)
            read!(reader, record)
            BAM.ismapped(record) && continue
            write(writer, ">$(BAM.tempname(record))\n$(BAM.sequence(record))\n")
        end
        close(writer)
        close(reader)
    end
end

function transcriptional_startsites(texreps::SingleTypeFiles, notexreps::SingleTypeFiles, results_gff::String)
    tex_coverage = Coverage(texreps)
    notex_coverage = Coverage(notexreps)
    tss_pos = tsss(tex_coverage, notex_coverage)
    tss_features = Features(tss_pos)
    write(results_gff, tss_features)
end

function full_annotation(features::Features, texdict::Dict{String,Coverage}, notexdict::Dict{String,Coverage}, termdict::Dict{String,Coverage}, results_gff::String;
                            cds_type="CDS", five_type="5UTR", three_type="3UTR", igr_type="IGR", min_tex_ratio=1.3, min_step=5, min_background_ratio=1.2, window_size=10)
    @assert keys(texdict) == keys(notexdict)
    tss_pos = Dict(key=>tsss(notexdict[key], texdict[key]; min_tex_ratio=min_tex_ratio, min_step=min_step, min_background_ratio=min_background_ratio, window_size=window_size) for key in keys(texdict))
    term_pos = Dict(key=>terms(termdict[key], min_step=min_step, min_background_ratio=min_background_ratio, window_size=window_size) for key in keys(termdict))
    addutrs!(features; tss_positions=tss_pos, term_positions=term_pos, cds_type=cds_type, five_type=five_type, three_type=three_type)
    addigrs!(features; igr_type=igr_type)
    write(results_gff, features)
end

function conserved_features(features::Features, source_genome::Genome, targets::SingleTypeFiles, results_path::String)
    target_genomes = [Genome(genome_file) for genome_file in targets]
    seqs = featureseqs(features, source_genome)
    align_mem(seqs, target_genomes, joinpath(results_path, "utrs.bam"))
    alignments = Alignments(joinpath(results_path, "utrs.bam"); hash_id=false)
    annotate!(features, alignments)
    write(joinpath(results_path, "features.gff"), features)
end

function rilseq_analysis(features::Features, bams::SingleTypeFiles, conditions::Dict{String, UnitRange{Int}}, results_path::String;
                            filter_types=["rRNA", "tRNA"], min_distance=1000, priorityze_type="sRNA", overwrite_type="IGR",
                            invert_strand=:read1, reverse_order=true, model=:fisher, overwrite_existing=false)
    isdir(joinpath(results_path, "interactions")) || mkdir(joinpath(results_path, "interactions"))
    isdir(joinpath(results_path, "singles")) || mkdir(joinpath(results_path, "singles"))
    for (condition, r) in conditions
        !overwrite_existing && isfile(joinpath(results_path, "interactions", "$(condition).csv")) && isfile(joinpath(results_path, "singles", "$(condition).csv")) && continue
        replicate_ids = Vector{Symbol}()
        interactions = Interactions()
        for (i, bam) in enumerate(bams[r])
            replicate_id = Symbol("$(condition)_$i")
            push!(replicate_ids, replicate_id)
            println("Reading $bam")
            alignments = Alignments(bam; only_unique=false, invert_strand=invert_strand, reverse_order=reverse_order)
            println("Annotating alignments...")
            annotate!(alignments, features; prioritize_type=priorityze_type, overwrite_type=overwrite_type)
            println("Building graph for replicate $replicate_id...")
            append!(interactions, alignments, replicate_id; min_distance=min_distance, filter_types=filter_types)
            empty!(alignments)
        end
        println("Computing significance levels and filtering...")
        annotate!(interactions, features; method=model)
        write(joinpath(results_path, "interactions", "$(condition).csv"), asdataframe(interactions; output=:edges))
        write(joinpath(results_path, "singles", "$(condition).csv"), asdataframe(interactions; output=:nodes))
    end
    (!overwrite_existing && isfile(joinpath(results_path, "singles.xlsx")) && isfile(joinpath(results_path, "interactions.xlsx"))) && return
    singles = CsvFiles(joinpath(results_path, "singles"))
	ints = CsvFiles(joinpath(results_path, "interactions"))
	write(joinpath(results_path, "singles.xlsx"), singles)
	write(joinpath(results_path, "interactions.xlsx"), ints)
end

function krona_plot_pipeline(
        db_location::String, sequence_file::String;
    )
    taxonomy_file = split(sequence_file, ".")[1] * ".report.txt"

    align_kraken2(db_location, sequence_file)
    kronaplot(taxonomy_file)
end
