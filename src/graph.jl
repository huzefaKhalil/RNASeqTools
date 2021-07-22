mutable struct Interactions <: InteractionContainer
    graph::MetaDiGraph
    replicate_ids::Vector{Symbol}
end

function order(tu::Tuple{String,String}, alignment::AlignedRead)
    for (i, part) in enumerate(alignment)
        (name(part), type(part)) == tu && (return i)
    end
    return -1
end

function order(tu::Tuple{String,String}, alignment1::AlignedRead, alignment2::AlignedRead)
    o1 = order(tu, alignment1)
    if o1 == -1 
        o2 = order(tu, alignment2)
        o2 == -1 && error("$tu not found in any alignment!")
        return o2 + length(alignment1)
    else
        return o1
    end
end

function ordered(tu_set::Set{Tuple{String,String}}, alignment1::AlignedRead, alignment2::AlignedRead)
    c = collect(tu_set)
    i = sortperm([order(tu, alignment1, alignment2) for tu in c])
    return c[i]
end

function refname(tu::Tuple{String,String}, alignment1::AlignedRead, alignment2::AlignedRead)
    for part in alignment1
        (name(part), type(part)) == tu && (return refname(part))
    end
    for part in alignment2
        (name(part), type(part)) == tu && (return refname(part))
    end
    return "NA"
end

function integrate!(alignments::PairedAlignments, graph::MetaDiGraph; replicate_id=:first, min_distance=200, filter_types=[])
    trans = Dict{Tuple{String,String}, Int}()
    for node in vertices(graph)
        trans[(get_prop(graph, node, :name), get_prop(graph, node, :type))] = node
    end
    for (alignment1, alignment2) in alignments
        if hasannotation(alignment1) && hasannotation(alignment2)
            !isempty(filter_types) && typein(alignment1, alignment2, filter_types) && continue
            chimeric = ischimeric(alignment1, alignment2; min_distance=min_distance)
            
            tu_set = union(Set((name(part),type(part)) for part in alignment1), Set((name(part),type(part)) for part in alignment2))
            tus = ordered(tu_set, alignment1, alignment2)
            nb_diff = length(Set(tu[1] for tu in tus))
            for tu in tus
                if !(tu in keys(trans))
                    trans[tu] = length(trans) + 1
                    add_vertex!(graph)
                    set_props!(graph, nv(graph), Dict(:name=>first(tu), :type=>last(tu), :refname=>refname(tu, alignment1, alignment2) :nb_ints=>0, :nb_single=>0))
                end
                chimeric ?
                set_prop!(graph, trans[tu], :nb_ints, get_prop(graph, trans[tu], :nb_ints)+nb_diff-1) :
                set_prop!(graph, trans[tu], :nb_single, get_prop(graph, trans[tu], :nb_single)+1)
            end

            if chimeric
                multi = nb_diff > 2
                for (a, b) in combinations([trans[tu] for tu in tus], 2)
                    get_prop(graph, a, :name) == get_prop(graph, b, :name) && continue
                    if add_edge!(graph, a, b)
                        set_props!(graph, a, b, Dict(:nb_ints=>1, :nb_multi=> (multi ? 1 : 0), replicate_id=>1))
                    else
                        set_prop!(graph, a, b, :nb_ints , get_prop(graph, a, b, :nb_ints) + 1)
                        set_prop!(graph, a, b, :nb_multi , get_prop(graph, a, b, :nb_multi) + (multi ? 1 : 0))
                    end
                    has_prop(graph, a, b, replicate_id) || set_prop!(graph, a, b, replicate_id, 1)
                end
            end
        end
    end
end

function Interactions()
    return Interactions(MetaDiGraph(), [])
end

function Interactions(alignments::PairedAlignments; replicate_id=:first, min_distance=200, filter_types=[])
    graph = MetaDiGraph()
    integrate!(alignments, graph; replicate_id=replicate_id, min_distance=min_distance, filter_types=filter_types)
    return Interactions(graph, [replicate_id])
end

function Base.append!(interactions::Interactions, alignments::PairedAlignments; replicate_id=:second, min_distance=200, filter_types=[])
    integrate!(alignments, interactions.graph; replicate_id=replicate_id, min_distance=min_distance, filter_types=filter_types)
    push!(interactions.replicate_ids, replicate_id)
end

function annotate!(interactions::Interactions; method=:disparity)
    @assert method in (:disparity, :fisher)
    pvalues = ones(ne(interactions.graph))
    if method === :fisher
        all_interactions = sum(get_prop(interactions.graph, node, :nb_ints) for node in vertices(interactions.graph))
        for (i,edge) in enumerate(edges(interactions.graph))
            ints_other_source = get_prop(interactions.graph, src(edge), :nb_ints)
            ints_other_target = get_prop(interactions.graph, dst(edge), :nb_ints)
            ints_between = get_prop(interactions.graph, edge, :nb_ints)
            test = FisherExactTest(ints_between, ints_other_target, ints_other_source, all_interactions)
            pvalues[i] = pvalue(test; tail=:right)
        end
    elseif method === :disparity
        for (i,edge) in enumerate(edges(interactions_graph))
            p_source = (1-get_prop(interactions.graph, edge, :nb_ints)/get_prop(interactions.graph, src(edge), :nb_ints))^(degree(interactions.graph, src(edge))-1)
            p_target = (1-get_prop(interactions.graph, edge, :nb_ints)/get_prop(interactions.graph, dst(edge), :nb_ints))^(degree(interactions.graph, dst(edge))-1)
            pvalues[i] = min(p_source, p_target)
        end
    end

    adjp = adjust(PValues(pvalues), BenjaminiHochberg())
    for (i, edge) in enumerate(edges(interactions.graph))
        set_prop!(interactions.graph, edge, :p_value, pvalues[i])
        set_prop!(interactions.graph, edge, :fdr, adjp[i])
    end
    return interactions
end

function asdataframe(interactions::Interactions; output=:edges, min_interactions=5)
    if output === :edges
        frame = DataFrame(name1=repeat([""], ne(interactions.graph)), type1=repeat([""], ne(interactions.graph)), ref1=repeat([""], ne(interactions.graph)), 
                        name2=repeat([""], ne(interactions.graph)), type2=repeat([""], ne(interactions.graph)), ref2=repeat([""], ne(interactions.graph)), 
                        nb_chimeras=repeat([0], ne(interactions.graph)), nb_multi=repeat([0], ne(interactions.graph)), p_value=repeat([1.], ne(interactions.graph)),
                        fdr=repeat([1.], ne(interactions.graph)), in_libs=repeat([0], ne(interactions.graph)))
        for (i,edge) in enumerate(edges(interactions.graph))
            frame[i, :name1] = get_prop(interactions.graph, src(edge), :name)
            frame[i, :type1] = get_prop(interactions.graph, src(edge), :type)
            frame[i, :ref1] = get_prop(interactions.graph, src(edge), :refname)
            frame[i, :name2] = get_prop(interactions.graph, dst(edge), :name)
            frame[i, :type2] = get_prop(interactions.graph, dst(edge), :type)
            frame[i, :ref2] = get_prop(interactions.graph, src(edge), :refname)
            frame[i, :nb_chimeras] = get_prop(interactions.graph, edge, :nb_ints)
            frame[i, :nb_multi] = get_prop(interactions.graph, edge, :nb_multi)
            frame[i, :in_libs] = sum(has_prop(interactions.graph, edge, replicate_id) for replicate_id in interactions.replicate_ids)
            has_prop(interactions.graph, edge, :p_value) && (frame[i, :p_value] = get_prop(interactions.graph, edge, :p_value))
            has_prop(interactions.graph, edge, :fdr) && (frame[i, :fdr] = get_prop(interactions.graph, edge, :fdr))
        end
        return filter(:nb_chimeras => >=(min_interactions), sort(frame, :nb_chimeras; rev=true))
    elseif output === :nodes
        frame = DataFrame(name=repeat([""], nv(interactions.graph)), type=repeat([""], nv(interactions.graph)), ref=repeat([""], nv(interactions.graph)),
                            nb_single=repeat([0], nv(interactions.graph)))
        for (i,node) in enumerate(vertices(interactions.graph))
            frame[i, :name] = get_prop(interactions.graph, node, :name)
            frame[i, :type] = get_prop(interactions.graph, node, :type)
            frame[i, :ref] = get_prop(interactions.graph, src(edge), :refname)
            frame[i, :nb_single] = get_prop(interactions.graph, node, :nb_single)
        end
        return sort(frame, :nb_single; rev=true)
    end         
end