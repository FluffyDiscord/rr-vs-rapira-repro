<?php

declare(strict_types=1);

namespace App\Controller;

use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

readonly class HomeController
{
    #[Route(path: '/', name: 'home', methods: ['GET'])]
    public function __invoke(): Response
    {
        return new Response('ok');
    }
}
